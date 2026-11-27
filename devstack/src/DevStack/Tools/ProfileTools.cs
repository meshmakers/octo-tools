using System.ComponentModel;
using Meshmakers.Octo.DevStack.Common;
using Meshmakers.Octo.DevStack.Configuration;
using Meshmakers.Octo.DevStack.Runtime;
using ModelContextProtocol.Server;

namespace Meshmakers.Octo.DevStack.Tools;

/// <summary>A profile in profile_list and on the status page.</summary>
public sealed record ProfileSummary(
    string Name,
    string? Description,
    string? Extends,
    string? BaseLane,
    string? Configuration,
    IReadOnlyList<string> Services,
    IReadOnlyList<string> Instances,
    string? ActiveIn,
    ProfileMatch? Match,
    string? Error)
{
    /// <summary>
    ///     Where the running profile's services come from when it runs in an environment: "branches/main + wt-&lt;env&gt;:
    ///     octo-identity-services" (the base lane plus the environment repos in use); null otherwise.
    /// </summary>
    [System.Text.Json.Serialization.JsonIgnore(Condition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull)]
    public string? RunsFrom { get; init; }
}

/// <summary>A profile with every layer merged (environment masked).</summary>
public sealed record ResolvedProfileView(
    string BaseLane,
    string Configuration,
    IReadOnlyList<string> Services,
    IReadOnlyDictionary<string, ProfileInstance> Instances,
    IReadOnlyDictionary<string, ServiceOverride> Overrides,
    IReadOnlyDictionary<string, string?> EnvVars,
    IReadOnlyDictionary<string, bool> EnvProviders,
    bool RequireInfra,
    string? Hash);

public sealed record ProfileDetail(string Name, IReadOnlyList<string> Chain, Profile? Profile, ResolvedProfileView? Resolved, string? Against, ProfileMatch? Drift);

public sealed record ProfileSaveResult(string Name, bool Replaced, Profile Profile, IReadOnlyList<string> SkippedEnv, IReadOnlyList<string> Notes);

/// <summary>Saved stack starts: list, inspect, compare, save (also from the running stack) and delete.</summary>
[McpServerToolType]
public sealed class ProfileTools(ConfigStore store, StackSupervisor supervisor, ILogger<ProfileTools> logger)
{
    [McpServerTool(Name = "profile_list", ReadOnly = true)]
    [Description("Lists the saved stack profiles (saved stack starts: which services, base lane, configuration, tenant, settings): name, " +
                 "description, base lane, configuration, the services and instances it starts, which profile it extends, and " +
                 "whether it is active - the shared stack runs it (activeIn='daemon'), a lane stack runs it (activeIn='slot:<name>', runsFrom " +
                 "names the base lane and the lane's repos in use), or a stack outside the daemon looks like it (activeIn=<external group " +
                 "key>) - with the differences (match.drift). Start one with stack_start(owner, profile=<name>, lane=...). Read-only.")]
    public Task<List<ProfileSummary>> List() =>
        ToolGuard.Run(async () => Summaries(store.Load(), await supervisor.StatusAsync(includeLogTail: false)));

    [McpServerTool(Name = "profile_get", ReadOnly = true)]
    [Description("Shows one profile: as written (resolved=false) or with its extends chain, settings and instances merged (resolved=true). " +
                 "Secret-looking environment values are masked. 'against' compares it: 'running' (the shared stack, else the stack " +
                 "outside the daemon), an external group key from stack_status, or another profile name - the result lists every " +
                 "difference (base lane, configuration, missing/extra services, source, args, ports). Read-only.")]
    public Task<ProfileDetail> Get(
        [Description("Profile name.")] string name,
        [Description("Merge extends, settings and instances into the view.")] bool resolved = false,
        [Description("'running', an external group key, or another profile name.")] string? against = null) =>
        ToolGuard.Run(async () =>
        {
            var config = store.Load();
            var profile = ProfileResolver.Get(config, name);
            var chain = ProfileResolver.Chain(config, name);
            var view = resolved ? ResolvedView(config, name) : null;

            ProfileMatch? drift = null;
            string? againstText = null;
            if (against != null)
            {
                (againstText, var observed) = await ObserveAsync(config, against, name);
                drift = ProfileMatcher.Compare(config, name, observed);
            }

            return new ProfileDetail(name, chain, resolved ? null : Mask(profile), view, againstText, drift);
        });

    [McpServerTool(Name = "admin_profile_save")]
    [Description("Admin (the developer's go): saves a profile in devstack.yaml, for every session: from 'spec' (the fields of stack_start - " +
                 "checkout = base lane, environment = envVars - plus description/extends/instances/settings), or capture='daemon' (the shared " +
                 "stack: base lane, configuration, services, worktree sources, overrides, instances, provider toggles and the non-secret stack " +
                 "environment variables) or capture=<external group key> (a stack outside the daemon: base lane, configuration, services, " +
                 "sources, differing args, a second process of a service as an instance by port; its environment is not readable); " +
                 "capture='daemon' with slot=<name> captures that stack slot and the profile keeps the slot. Secret-looking environment keys " +
                 "are never saved; they are listed in skippedEnv. Validated like every config change. overwrite=true replaces an existing profile.")]
    public Task<ProfileSaveResult> Save(
        [Description("Who changes the config (logged).")] string owner,
        [Description("Profile name (letters, digits, -, _).")] string name,
        [Description("The profile; omit when capturing.")] Profile? spec = null,
        [Description("'daemon' or an external group key from stack_status.")] string? capture = null,
        [Description("Description of the profile (overrides the one in spec).")] string? description = null,
        [Description("Replace an existing profile of that name.")] bool overwrite = false,
        [Description("With capture='daemon': the stack slot to capture (default: the shared stack); the profile keeps the slot.")] string? slot = null,
        [Description(StackTools.SessionDescription)] string? session = null) =>
        ToolGuard.Run(async () =>
        {
            if (!ProfileResolver.IsValidName(name))
            {
                throw new ArgumentException($"Invalid profile name '{name}' (letters, digits, -, _).");
            }

            if ((spec == null) == (capture == null))
            {
                throw new ArgumentException("Pass either spec or capture.");
            }

            var config = store.Load();
            var skipped = new List<string>();
            var notes = new List<string>();
            Profile profile;
            if (spec != null)
            {
                profile = spec;
                foreach (var key in SecretKeys(profile))
                {
                    skipped.Add(key);
                }

                RemoveSecrets(profile);
            }
            else if (capture == "daemon")
            {
                profile = CaptureDaemon(config, skipped, slot);
            }
            else
            {
                var status = await supervisor.StatusAsync(includeLogTail: false);
                var group = status.External.Groups.FirstOrDefault(g => g.Key == capture)
                            ?? throw new InvalidOperationException(
                                $"No stack '{capture}' to capture. Use 'daemon' or an external group key: {(status.External.Groups.Count == 0 ? "none running" : string.Join(", ", status.External.Groups.Select(g => g.Key)))}.");
                profile = ProfileCapture.FromProcesses(config, group.Checkout, group.Configuration, status.External.Services
                    .Where(s => s.Group == group.Key)
                    .Select(s => new ProfileCapture.Process(s.Service, s.Source, ProfileMatcher.ArgsOf(s.Command), s.Ports)).ToList(), skipped);
                notes.Add("The environment variables of processes outside the daemon are not readable; settings and envVars were not captured.");
                if (status.External.Skipped is { Count: > 0 } leftOut)
                {
                    // AB#9924: a process the scan could not analyse is in no group, so the profile may lack the service it runs.
                    notes.Add(ExternalDetector.LeftOut(leftOut) + " The profile may lack a service one of them runs.");
                }
            }

            if (description != null)
            {
                profile.Description = description;
            }

            var replaced = false;
            store.Update(c =>
            {
                if (c.Profiles.ContainsKey(name))
                {
                    if (!overwrite)
                    {
                        throw new InvalidOperationException($"Profile '{name}' exists. Pass overwrite=true to replace it.");
                    }

                    replaced = true;
                }

                c.Profiles[name] = profile;
            });
            logger.LogInformation("{Owner} ({Session}) {Action} profile {Profile}", owner, session ?? "-", replaced ? "replaced" : "saved", name);
            return new ProfileSaveResult(name, replaced, Mask(profile), skipped, notes);
        });

    [McpServerTool(Name = "admin_profile_delete", Destructive = true)]
    [Description("Admin (the developer's go): removes a profile from devstack.yaml. Refused while another profile extends it. A stack running " +
                 "from it keeps running.")]
    public string Delete(
        [Description("Who changes the config (logged).")] string owner,
        [Description("Profile name.")] string name,
        [Description(StackTools.SessionDescription)] string? session = null) =>
        ToolGuard.Run(() =>
        {
            store.Update(c =>
            {
                ProfileResolver.Get(c, name);
                var children = ProfileResolver.Children(c, name);
                if (children.Count > 0)
                {
                    throw new InvalidOperationException($"Profile '{name}' is extended by {string.Join(", ", children)}; change or delete those first.");
                }

                c.Profiles.Remove(name);
            });
            logger.LogInformation("{Owner} ({Session}) deleted profile {Profile}", owner, session ?? "-", name);
            return $"Profile '{name}' deleted.";
        });

    /// <summary>Every profile with what it starts and whether it runs (for profile_list and the status page).</summary>
    public static List<ProfileSummary> Summaries(DevStackConfig config, StackStatus status) =>
        config.Profiles.Select(p =>
        {
            string? activeIn = null;
            string? runsFrom = null;
            ProfileMatch? match = null;
            if (status.Profile?.Profile == p.Key)
            {
                (activeIn, match) = ("daemon", status.Profile);
            }
            else if (status.Slots?.FirstOrDefault(s => s.Name != SlotInfo.DefaultName && s.Running && s.Profile == p.Key) is { } slot)
            {
                activeIn = $"slot:{slot.Name}";
                runsFrom = RunsFrom(config, slot);
            }
            else if (status.External.Groups.FirstOrDefault(g => g.Profile?.Profile == p.Key) is { } group)
            {
                (activeIn, match) = (group.Key, group.Profile);
            }

            try
            {
                var r = ProfileResolver.Resolve(config, p.Key, null);
                return new ProfileSummary(p.Key, p.Value.Description, p.Value.Extends, r.Checkout, r.Configuration, r.Services, r.Instances.Keys.ToList(),
                    activeIn, match, null) { RunsFrom = runsFrom };
            }
            catch (InvalidOperationException e)
            {
                return new ProfileSummary(p.Key, p.Value.Description, p.Value.Extends, null, null, [], [], activeIn, match, e.Message);
            }
        }).ToList();

    /// <summary>"&lt;base&gt; + wt-&lt;env&gt;: repo, repo" for a slot that runs from an environment, else null.</summary>
    internal static string? RunsFrom(DevStackConfig config, SlotSummary slot)
    {
        var root = ServicePlanner.RootPath(config);
        if (slot.Folder == null || Discovery.EnvironmentDiscovery.OfCheckout(slot.Folder, root) is not { Problem: null } env)
        {
            return null;
        }

        var own = env.RepoPaths();
        var used = slot.Services.Where(s => s.RepoPath != null)
            .Select(s => own.FirstOrDefault(o => PathScope.SamePath(o.Value, s.RepoPath!)).Key)
            .Where(k => k != null).Distinct().Order(StringComparer.Ordinal).ToList();
        var baseLane = env.BasePath == null ? env.Manifest?.Base : PathScope.Relative(env.BasePath, root);
        return used.Count == 0
            ? $"{baseLane} (wt-{env.Name} runs none of its repos)"
            : $"{baseLane} + {PathScope.Relative(env.Path, root)}: {string.Join(", ", used)}";
    }

    private async Task<(string Text, ObservedStack Observed)> ObserveAsync(DevStackConfig config, string against, string self)
    {
        if (config.Profiles.ContainsKey(against) && against != self)
        {
            return ($"profile {against}", ProfileMatcher.ExpectedStack(config, against));
        }

        var status = await supervisor.StatusAsync(includeLogTail: false);
        if (against == "running")
        {
            if (status.Running)
            {
                return ("the daemon's stack", ProfileMatcher.FromStatus(status));
            }

            if (status.External.Groups.FirstOrDefault() is { } first)
            {
                return ($"the stack outside the daemon ({first.Key})", ProfileMatcher.FromExternal(status.External, first));
            }

            throw new InvalidOperationException("No stack is running.");
        }

        var group = status.External.Groups.FirstOrDefault(g => g.Key == against)
                    ?? throw new InvalidOperationException(
                        $"'{against}' is no profile and no running stack. Use 'running', an external group key " +
                        $"({(status.External.Groups.Count == 0 ? "none running" : string.Join(", ", status.External.Groups.Select(g => g.Key)))}) " +
                        $"or a profile: {string.Join(", ", config.Profiles.Keys)}.");
        return ($"the stack outside the daemon ({group.Key})", ProfileMatcher.FromExternal(status.External, group));
    }

    private Profile CaptureDaemon(DevStackConfig config, List<string> skipped, string? slot)
    {
        var capture = supervisor.Capture(slot) ?? throw new InvalidOperationException(
            $"The daemon runs no stack{(slot is null or SlotInfo.DefaultName ? "" : $" in slot '{slot}'")} to capture. Use an external group key, or spec.");
        var root = ServicePlanner.RootPath(config);
        var (env, skippedEnv) = ProfileCapture.FilterEnv(capture.RequestEnv);
        skipped.AddRange(skippedEnv);
        var profile = new Profile
        {
            Checkout = ProfileCapture.Relative(capture.Checkout, root),
            Configuration = capture.Configuration,
            Services = capture.Services.Select(s => s.Name).Where(n => !capture.Instances.ContainsKey(n)).ToList(),
            Environment = env.Count > 0 ? env : null,
            EnvProviders = capture.EnvProviders.Count > 0 ? capture.EnvProviders.ToDictionary() : null,
            Description = capture.Profile != null ? $"Captured from the stack started with profile {capture.Profile}" : "Captured from the running stack",
            Slot = capture.Slot == SlotInfo.DefaultName ? null : capture.Slot
        };

        foreach (var (name, o) in capture.Services)
        {
            if (capture.Instances.TryGetValue(name, out var instance))
            {
                // Copies: removing secrets below must not change the running stack's definitions.
                (profile.Instances ??= new Dictionary<string, ProfileInstance>())[name] = new ProfileInstance
                {
                    Of = instance.Of, Ports = instance.Ports, HealthUrl = instance.HealthUrl, LogName = instance.LogName, Source = instance.Source,
                    Args = instance.Args, ExtraArgs = instance.ExtraArgs, Variables = instance.Variables,
                    Env = instance.Env == null ? null : new Dictionary<string, string?>(instance.Env)
                };
            }
            else if (o != null)
            {
                (profile.Overrides ??= new Dictionary<string, ServiceOverride>())[name] = ProfileResolver.MergeOverride(new ServiceOverride(), o);
            }
        }

        skipped.AddRange(SecretKeys(profile));
        RemoveSecrets(profile);
        return profile;
    }

    // ---------- secrets ----------

    private static IEnumerable<Dictionary<string, string?>> EnvMaps(StartSpec spec)
    {
        if (spec.Environment != null) yield return spec.Environment;
        foreach (var o in spec.Overrides?.Values ?? Enumerable.Empty<ServiceOverride>())
        {
            if (o.Env != null) yield return o.Env;
        }

        foreach (var i in spec.Instances?.Values ?? Enumerable.Empty<ProfileInstance>())
        {
            if (i.Env != null) yield return i.Env;
        }
    }

    private static List<string> SecretKeys(StartSpec spec) =>
        EnvMaps(spec).SelectMany(m => m.Where(kv => kv.Value != null && SecretMask.IsSecretName(kv.Key)).Select(kv => kv.Key)).Distinct().ToList();

    /// <summary>Credentials are not stored in profiles: secret-looking keys with a value are dropped (removals stay).</summary>
    private static void RemoveSecrets(StartSpec spec)
    {
        foreach (var map in EnvMaps(spec).ToList())
        {
            foreach (var key in map.Where(kv => kv.Value != null && SecretMask.IsSecretName(kv.Key)).Select(kv => kv.Key).ToList())
            {
                map.Remove(key);
            }
        }
    }

    /// <summary>A profile with every layer merged, secret-looking values masked (profile_get and the status page's inspector).</summary>
    internal static ResolvedProfileView ResolvedView(DevStackConfig config, string name)
    {
        var r = ProfileResolver.Resolve(config, name, null);
        return new ResolvedProfileView(r.Checkout, r.Configuration, r.Services,
            r.Instances.ToDictionary(i => i.Key, i => MaskInstance(i.Value)),
            r.Overrides.ToDictionary(o => o.Key, o => MaskOverride(o.Value)),
            MaskEnv(r.Environment.ToDictionary())!, r.EnvProviders, r.RequireInfra, r.ProfileHash);
    }

    /// <summary>A profile as written (its own fields), secret-looking values masked.</summary>
    internal static Profile AsWritten(Profile p) => Mask(p);

    private static Dictionary<string, string?>? MaskEnv(Dictionary<string, string?>? env) => env == null ? null : SecretMask.MaskNullable(env);

    private static Dictionary<string, string>? MaskVariables(Dictionary<string, string>? variables) => variables == null ? null : SecretMask.Mask(variables);

    private static List<string>? MaskArgs(List<string>? args) => args == null ? null : SecretMask.MaskArgs(args);

    private static ServiceOverride MaskOverride(ServiceOverride o) => new()
    {
        Source = o.Source, Args = MaskArgs(o.Args), ExtraArgs = MaskArgs(o.ExtraArgs), Env = MaskEnv(o.Env), Variables = MaskVariables(o.Variables)
    };

    private static ProfileInstance MaskInstance(ProfileInstance i) => new()
    {
        Of = i.Of, Ports = i.Ports, HealthUrl = i.HealthUrl, LogName = i.LogName,
        Source = i.Source, Args = MaskArgs(i.Args), ExtraArgs = MaskArgs(i.ExtraArgs), Env = MaskEnv(i.Env), Variables = MaskVariables(i.Variables)
    };

    private static Profile Mask(Profile p) => new()
    {
        Description = p.Description,
        Extends = p.Extends,
        Checkout = p.Checkout,
        Configuration = p.Configuration,
        Services = p.Services,
        Exclude = p.Exclude,
        Overrides = p.Overrides?.ToDictionary(o => o.Key, o => MaskOverride(o.Value)),
        Environment = MaskEnv(p.Environment),
        Instances = p.Instances?.ToDictionary(i => i.Key, i => MaskInstance(i.Value)),
        EnvProviders = p.EnvProviders,
        Settings = p.Settings,
        RequireInfra = p.RequireInfra,
        Slot = p.Slot
    };
}
