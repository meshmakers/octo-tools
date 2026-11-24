using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;

namespace Meshmakers.Octo.DevStack.Configuration;

/// <summary>A stack start with every layer merged: what the supervisor runs.</summary>
public sealed record ResolvedStart(
    string? Profile,
    string? ProfileHash,
    string Checkout,
    string Configuration,
    IReadOnlyList<string> Services,
    IReadOnlyDictionary<string, ServiceOverride> Overrides,
    IReadOnlyDictionary<string, string?> Environment,
    IReadOnlyDictionary<string, ProfileInstance> Instances,
    IReadOnlyDictionary<string, bool> EnvProviders,
    bool RequireInfra,
    DevStackConfig Config,
    StartSpec Spec)
{
    /// <summary>The slot the start runs in ('default' unless the spec names one).</summary>
    public string Slot => Spec.Slot ?? SlotInfo.DefaultName;

    /// <summary>Exclusive services left out because the start runs in another slot and did not list services explicitly.</summary>
    public IReadOnlyList<string> Dropped { get; init; } = [];
}

/// <summary>
///     Profiles: merging the layers of a start, materializing instances and validating profiles. Merge order (later wins):
///     devstack.yaml root defaults, the extends chain (root ancestor first), the profile, the ad-hoc stack_start arguments.
/// </summary>
public static partial class ProfileResolver
{
    [GeneratedRegex("^[A-Za-z0-9_-]+$")]
    private static partial Regex NameRegex();

    public static bool IsValidName(string? name) => !string.IsNullOrEmpty(name) && NameRegex().IsMatch(name);

    // ---------- merging ----------

    /// <summary>
    ///     Merges <paramref name="layer"/> over <paramref name="into"/> into a new spec: checkout/configuration replace;
    ///     services replaces when set; exclude unions; instances replace per name; environment and envProviders merge per key
    ///     (a null env value is kept: it removes the variable at start); overrides merge field-wise (source/args replace,
    ///     extraArgs concatenate, env/variables per key); settings merge field-wise.
    /// </summary>
    public static StartSpec Merge(StartSpec into, StartSpec layer)
    {
        var result = new StartSpec
        {
            Checkout = layer.Checkout ?? into.Checkout,
            Configuration = layer.Configuration ?? into.Configuration,
            Services = layer.Services is { Count: > 0 } ? [..layer.Services] : into.Services is null ? null : [..into.Services],
            Exclude = Union(into.Exclude, layer.Exclude),
            Environment = MergeMap(into.Environment, layer.Environment),
            EnvProviders = MergeMap(into.EnvProviders, layer.EnvProviders),
            RequireInfra = layer.RequireInfra ?? into.RequireInfra,
            Slot = layer.Slot ?? into.Slot,
            Settings = MergeSettings(into.Settings, layer.Settings)
        };

        if (into.Instances != null || layer.Instances != null)
        {
            result.Instances = new Dictionary<string, ProfileInstance>(into.Instances ?? [], StringComparer.Ordinal);
            foreach (var (name, instance) in layer.Instances ?? [])
            {
                result.Instances[name] = instance;
            }
        }

        if (into.Overrides != null || layer.Overrides != null)
        {
            result.Overrides = new Dictionary<string, ServiceOverride>(StringComparer.Ordinal);
            foreach (var (name, o) in into.Overrides ?? [])
            {
                result.Overrides[name] = MergeOverride(new ServiceOverride(), o);
            }

            foreach (var (name, o) in layer.Overrides ?? [])
            {
                result.Overrides[name] = MergeOverride(result.Overrides.GetValueOrDefault(name) ?? new ServiceOverride(), o);
            }
        }

        return result;
    }

    public static ServiceOverride MergeOverride(ServiceOverride into, ServiceOverride layer) => new()
    {
        Source = layer.Source ?? into.Source,
        Args = layer.Args is null ? into.Args is null ? null : [..into.Args] : [..layer.Args],
        ExtraArgs = into.ExtraArgs is null && layer.ExtraArgs is null ? null : [..into.ExtraArgs ?? [], ..layer.ExtraArgs ?? []],
        Env = MergeMap(into.Env, layer.Env),
        Variables = MergeMap(into.Variables, layer.Variables)
    };

    private static List<string>? Union(List<string>? a, List<string>? b) =>
        a is null && b is null ? null : (a ?? []).Concat(b ?? []).Distinct(StringComparer.Ordinal).ToList();

    private static Dictionary<string, T>? MergeMap<T>(Dictionary<string, T>? a, Dictionary<string, T>? b)
    {
        if (a is null && b is null)
        {
            return null;
        }

        var result = new Dictionary<string, T>(a ?? [], StringComparer.Ordinal);
        foreach (var (key, value) in b ?? [])
        {
            result[key] = value;
        }

        return result;
    }

    private static ProfileSettings? MergeSettings(ProfileSettings? a, ProfileSettings? b)
    {
        if (a is null || b is null)
        {
            return b ?? a;
        }

        return new ProfileSettings
        {
            SystemDatabase = b.SystemDatabase ?? a.SystemDatabase,
            Mongo = a.Mongo is null || b.Mongo is null
                ? b.Mongo ?? a.Mongo
                : new MongoSettings
                {
                    Host = b.Mongo.Host ?? a.Mongo.Host,
                    DirectConnection = b.Mongo.DirectConnection ?? a.Mongo.DirectConnection,
                    ReplicaSet = b.Mongo.ReplicaSet ?? a.Mongo.ReplicaSet
                },
            Broker = a.Broker is null || b.Broker is null
                ? b.Broker ?? a.Broker
                : new BrokerSettings
                {
                    Host = b.Broker.Host ?? a.Broker.Host,
                    Port = b.Broker.Port ?? a.Broker.Port,
                    Vhost = b.Broker.Vhost ?? a.Broker.Vhost,
                    InstancePrefix = b.Broker.InstancePrefix ?? a.Broker.InstancePrefix
                },
            AuthorityUrl = b.AuthorityUrl ?? a.AuthorityUrl,
            StreamData = a.StreamData is null || b.StreamData is null
                ? b.StreamData ?? a.StreamData
                : new StreamDataSettings
                {
                    Enabled = b.StreamData.Enabled ?? a.StreamData.Enabled,
                    SchemaInstancePrefix = b.StreamData.SchemaInstancePrefix ?? a.StreamData.SchemaInstancePrefix
                },
            ArtifactStorage = b.ArtifactStorage ?? a.ArtifactStorage,
            MeshAdapter = a.MeshAdapter is null || b.MeshAdapter is null
                ? b.MeshAdapter ?? a.MeshAdapter
                : new MeshAdapterSettings
                {
                    TenantId = b.MeshAdapter.TenantId ?? a.MeshAdapter.TenantId,
                    AdapterRtId = b.MeshAdapter.AdapterRtId ?? a.MeshAdapter.AdapterRtId
                },
            HttpActivator = a.HttpActivator is null || b.HttpActivator is null
                ? b.HttpActivator ?? a.HttpActivator
                : new HttpActivatorSettings
                {
                    Enabled = b.HttpActivator.Enabled ?? a.HttpActivator.Enabled,
                    AddressTemplate = b.HttpActivator.AddressTemplate ?? a.HttpActivator.AddressTemplate
                },
            LogLevel = b.LogLevel ?? a.LogLevel
        };
    }

    // ---------- profiles ----------

    public static Profile Get(DevStackConfig config, string name) =>
        config.Profiles.TryGetValue(name, out var profile)
            ? profile
            : throw new InvalidOperationException(
                $"Unknown profile '{name}'. Known: {(config.Profiles.Count == 0 ? "none" : string.Join(", ", config.Profiles.Keys))}.");

    /// <summary>The extends chain of a profile, root ancestor first, the profile last.</summary>
    public static List<string> Chain(DevStackConfig config, string name)
    {
        var chain = new List<string>();
        var current = name;
        while (current != null)
        {
            if (chain.Contains(current))
            {
                throw new InvalidOperationException($"extends cycle: {string.Join(" -> ", chain.Append(current))}.");
            }

            chain.Add(current);
            current = Get(config, current).Extends;
        }

        chain.Reverse();
        return chain;
    }

    /// <summary>The profile with its ancestors merged (without the devstack.yaml defaults).</summary>
    public static StartSpec Flatten(DevStackConfig config, string name) =>
        Chain(config, name).Aggregate(new StartSpec(), (spec, n) => Merge(spec, config.Profiles[n]));

    /// <summary>Short hash of the flattened profile: changes when the profile or one of its ancestors is edited.</summary>
    public static string Hash(DevStackConfig config, string name)
    {
        var yaml = ConfigStore.SerializeObject(Flatten(config, name));
        return Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(yaml)))[..12];
    }

    /// <summary>Profiles that name <paramref name="name"/> in extends.</summary>
    public static List<string> Children(DevStackConfig config, string name) =>
        config.Profiles.Where(p => p.Value.Extends == name).Select(p => p.Key).ToList();

    // ---------- resolution ----------

    /// <summary>Merges every layer of a start and materializes its instances. Throws on unknown names, clashes and bad settings.</summary>
    public static ResolvedStart Resolve(DevStackConfig config, string? profile, StartSpec? adhoc)
    {
        var spec = new StartSpec { Checkout = config.DefaultCheckout, Configuration = config.Configuration };
        string? hash = null;
        if (profile != null)
        {
            spec = Merge(spec, Flatten(config, profile));
            hash = Hash(config, profile);
        }

        if (adhoc != null)
        {
            spec = Merge(spec, adhoc);
        }

        var instances = spec.Instances ?? new Dictionary<string, ProfileInstance>();
        foreach (var (name, instance) in instances)
        {
            ValidateInstance(config, name, instance);
        }

        bool Known(string n) => config.Services.ContainsKey(n) || instances.ContainsKey(n);
        string KnownList() => string.Join(", ", config.Services.Keys.Concat(instances.Keys));
        foreach (var (what, list) in new[] { ("services", spec.Services), ("exclude", spec.Exclude), ("overrides", spec.Overrides?.Keys.ToList()) })
        {
            foreach (var n in list ?? [])
            {
                if (!Known(n))
                {
                    throw new InvalidOperationException($"Unknown service '{n}' in {what}. Configured: {KnownList()}.");
                }
            }
        }

        var expansion = SettingsMap.Expand(spec.Settings);
        var providers = new Dictionary<string, bool>(expansion.EnvProviders, StringComparer.Ordinal);
        foreach (var (key, value) in spec.EnvProviders ?? [])
        {
            providers[key] = value;
        }

        foreach (var key in providers.Keys.Where(k => !config.EnvProviders.ContainsKey(k)))
        {
            throw new InvalidOperationException($"Unknown env provider '{key}'. Configured: {string.Join(", ", config.EnvProviders.Keys)}.");
        }

        var materialized = Materialize(config, instances, providers);
        var exclude = spec.Exclude ?? [];
        var slot = spec.Slot ?? SlotInfo.DefaultName;
        if (!SlotRules.IsValidName(slot))
        {
            throw new InvalidOperationException(SlotRules.NameRule(slot));
        }

        var dropped = new List<string>();
        var names = (spec.Services is { Count: > 0 }
                ? spec.Services.Distinct(StringComparer.Ordinal)
                : materialized.Services.Where(s => s.Value.Enabled && !instances.ContainsKey(s.Key)).Select(s => s.Key))
            .Concat(instances.Keys)
            .Distinct(StringComparer.Ordinal)
            .Where(n => !exclude.Contains(n))
            .ToList();
        if (slot != SlotInfo.DefaultName && spec.Services is not { Count: > 0 })
        {
            // "Every enabled service" in another slot means the backend: the frontends run in the default slot only.
            dropped = names.Where(n => SlotRules.IsExclusive(materialized, n)).ToList();
            names = names.Except(dropped).ToList();
        }

        foreach (var key in adhoc?.Overrides?.Keys.ToList() ?? [])
        {
            if (!names.Contains(key))
            {
                throw new InvalidOperationException($"Override for '{key}', but '{key}' is not started by this call.");
            }
        }

        // Overrides of services this start leaves out (e.g. inherited from a broader profile) are dropped.
        var overrides = new Dictionary<string, ServiceOverride>(StringComparer.Ordinal);
        foreach (var (service, vars) in expansion.Variables)
        {
            if (names.Contains(service))
            {
                overrides[service] = new ServiceOverride { Variables = new Dictionary<string, string>(vars) };
            }
        }

        foreach (var (name, instance) in instances)
        {
            if (names.Contains(name) && instance.Source != null)
            {
                overrides[name] = new ServiceOverride { Source = instance.Source };
            }
        }

        foreach (var (name, o) in spec.Overrides ?? [])
        {
            if (names.Contains(name))
            {
                overrides[name] = MergeOverride(overrides.GetValueOrDefault(name) ?? new ServiceOverride(), o);
            }
        }

        var env = new Dictionary<string, string?>(expansion.Env, StringComparer.Ordinal);
        foreach (var (key, value) in spec.Environment ?? [])
        {
            env[key] = value;
        }

        CheckPorts(materialized, names);

        if (slot != SlotInfo.DefaultName)
        {
            SlotRules.CheckSpec(materialized, slot, names, spec, env);
        }

        return new ResolvedStart(profile, hash, spec.Checkout!, spec.Configuration!, names, overrides, env, instances, providers,
            spec.RequireInfra ?? false, materialized, spec) { Dropped = dropped };
    }

    /// <summary>
    ///     A copy of the configuration with every instance added as a clone of its base service and the env provider toggles
    ///     applied, so planning, ordering and the port preflight need no knowledge of profiles.
    /// </summary>
    public static DevStackConfig Materialize(DevStackConfig config, IReadOnlyDictionary<string, ProfileInstance>? instances,
        IReadOnlyDictionary<string, bool>? providers)
    {
        var copy = new DevStackConfig
        {
            Server = config.Server,
            RootPath = config.RootPath,
            OctoToolsPath = config.OctoToolsPath,
            DefaultCheckout = config.DefaultCheckout,
            Configuration = config.Configuration,
            TargetFramework = config.TargetFramework,
            LogDirectory = config.LogDirectory,
            StopTimeoutSeconds = config.StopTimeoutSeconds,
            Environment = config.Environment,
            Profiles = config.Profiles,
            Slots = config.Slots,
            SlotOptions = config.SlotOptions,
            SlotDerivations = config.SlotDerivations,
            EffectiveSlotDerivations = config.EffectiveSlotDerivations,
            Services = new Dictionary<string, ServiceConfig>(config.Services),
            EnvProviders = config.EnvProviders.ToDictionary(p => p.Key, p => new EnvProviderConfig
            {
                Enabled = providers != null && providers.TryGetValue(p.Key, out var on) ? on : p.Value.Enabled,
                Script = p.Value.Script,
                WhenServices = p.Value.WhenServices
            })
        };

        foreach (var (name, instance) in instances ?? new Dictionary<string, ProfileInstance>())
        {
            ValidateInstance(config, name, instance);
            var clone = config.Services[instance.Of!].Clone();
            clone.Description = $"Instance '{name}' of {instance.Of}";
            if (instance.Args != null)
            {
                clone.Args = [..instance.Args];
            }

            clone.Args.AddRange(instance.ExtraArgs ?? []);
            foreach (var (key, value) in instance.Env ?? [])
            {
                if (value == null)
                {
                    clone.Env.Remove(key);
                }
                else
                {
                    clone.Env[key] = value;
                }
            }

            foreach (var (key, value) in instance.Variables ?? [])
            {
                clone.Variables[key] = value;
            }

            if (instance.Ports != null)
            {
                clone.Ports = [..instance.Ports];
            }

            clone.HealthUrl = instance.HealthUrl ?? clone.HealthUrl;
            clone.LogName = instance.LogName ?? name;
            clone.Enabled = true;
            // The base service announces its URL; a second copy would announce the same one again.
            clone.AnnounceEnv = new Dictionary<string, string>();
            copy.Services[name] = clone;
        }

        return copy;
    }

    private static void ValidateInstance(DevStackConfig config, string name, ProfileInstance instance)
    {
        if (!IsValidName(name))
        {
            throw new InvalidOperationException($"Invalid instance name '{name}' (letters, digits, -, _).");
        }

        if (config.Services.ContainsKey(name))
        {
            throw new InvalidOperationException($"Instance '{name}' has the name of a configured service.");
        }

        if (string.IsNullOrEmpty(instance.Of) || !config.Services.TryGetValue(instance.Of, out var service))
        {
            throw new InvalidOperationException(
                $"Instance '{name}': 'of' must name a configured service ({string.Join(", ", config.Services.Keys)}), not '{instance.Of}'.");
        }

        foreach (var key in instance.Variables?.Keys.ToList() ?? [])
        {
            if (ServicePlanner.BuiltInVariables.Contains(key))
            {
                throw new InvalidOperationException($"Instance '{name}': variable '{key}' is built in.");
            }

            if (!service.Variables.ContainsKey(key))
            {
                throw new InvalidOperationException(
                    $"Instance '{name}': {instance.Of} has no variable '{key}'. Its variables: {(service.Variables.Count == 0 ? "none" : string.Join(", ", service.Variables.Keys))}.");
            }
        }
    }

    private static void CheckPorts(DevStackConfig materialized, IReadOnlyList<string> names)
    {
        var owners = new Dictionary<int, string>();
        foreach (var name in names)
        {
            foreach (var port in materialized.Services[name].Ports)
            {
                if (owners.TryGetValue(port, out var other))
                {
                    throw new InvalidOperationException(
                        $"Port {port} is used by both '{other}' and '{name}'. Give the instance its own ports (and --urls in extraArgs).");
                }

                owners[port] = name;
            }
        }
    }

    // ---------- validation ----------

    /// <summary>A stack context that does not need the checkout to exist (validation, matching).</summary>
    public static StackContext DryRunContext(DevStackConfig config, string checkout, string configuration)
    {
        // Without a workspace (the built-in default, a config parsed on its own) the plans are checked against a root that
        // does not exist: validation looks at placeholders and names, never at folders.
        var root = ServicePlanner.RootPath(config) is { Length: > 0 } known ? known : Path.Combine(Path.GetTempPath(), "octo-devstack-workspace-unknown");
        var path = checkout.StartsWith('~') || Path.IsPathRooted(checkout)
            ? TemplateExpander.ExpandPath(checkout)
            : Path.GetFullPath(Path.Combine(root, checkout));
        var env = Discovery.EnvironmentDiscovery.OfCheckout(path, root);
        return new StackContext(root, path.TrimEnd(Path.DirectorySeparatorChar), configuration, config.TargetFramework,
            Path.GetFullPath(Path.Combine(path, config.LogDirectory)))
        {
            Environment = env?.Problem == null ? env?.Name : null,
            Base = env?.BasePath,
            EnvironmentRepos = env?.Problem == null ? env?.RepoPaths() : null
        };
    }

    /// <summary>Plans every service of a resolved start without touching the disk (sources are not resolved).</summary>
    public static List<ServicePlan> DryRunPlans(ResolvedStart resolved, StackContext context) =>
        resolved.Services.Select(name =>
        {
            var o = resolved.Overrides.GetValueOrDefault(name);
            var withoutSource = o == null ? null : new ServiceOverride { Args = o.Args, ExtraArgs = o.ExtraArgs, Env = o.Env, Variables = o.Variables };
            return ServicePlanner.Plan(resolved.Config, context, name, withoutSource, new Dictionary<string, string?>());
        }).ToList();

    /// <summary>Checks every profile: names, extends, instances, referenced services and providers, a dry-run plan, ports.</summary>
    public static void Validate(DevStackConfig config, string source)
    {
        foreach (var (name, profile) in config.Profiles)
        {
            try
            {
                if (!IsValidName(name))
                {
                    throw new InvalidOperationException("invalid name (letters, digits, -, _).");
                }

                if (profile.Extends != null && !config.Profiles.ContainsKey(profile.Extends))
                {
                    throw new InvalidOperationException($"extends unknown profile '{profile.Extends}'.");
                }

                var resolved = Resolve(config, name, null);
                DryRunPlans(resolved, DryRunContext(config, resolved.Checkout, resolved.Configuration));
            }
            catch (InvalidOperationException e)
            {
                throw new InvalidOperationException($"{source}: profile '{name}': {e.Message}", e);
            }
        }
    }
}
