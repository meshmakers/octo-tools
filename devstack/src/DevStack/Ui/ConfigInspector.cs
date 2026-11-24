using System.Text.Json.Serialization;
using Meshmakers.Octo.DevStack.Common;
using Meshmakers.Octo.DevStack.Configuration;
using Meshmakers.Octo.DevStack.Discovery;
using Meshmakers.Octo.DevStack.Runtime;
using Meshmakers.Octo.DevStack.Tools;

namespace Meshmakers.Octo.DevStack.Ui;

/// <summary>A service definition with what it resolves to in the default checkout.</summary>
public sealed record InspectedService(
    ServiceView Definition,
    bool Exclusive,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    string? RepoPath,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    string? WorkingDirectory,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    string? Problem);

/// <summary>A profile: its extends chain, its own fields (what it sets or overrides) and the merged result.</summary>
public sealed record InspectedProfile(
    string Name,
    IReadOnlyList<string> Chain,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    Profile? AsWritten,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    ResolvedProfileView? Resolved,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    string? Error);

/// <summary>A slot: summary, state (running / reserved / configured), the ports of every service and the evaluated derivation rows.</summary>
public sealed record InspectedSlot(string Name, int Index, int PortOffset, string Prefix, string State, string Origin,
    IReadOnlyDictionary<string, IReadOnlyList<int>> Ports, IReadOnlyDictionary<string, string> Derived);

/// <summary>A retired slot index with its facts.</summary>
public sealed record InspectedRetiredSlot(int Index, string Name, string Prefix, int PortOffset, DateTimeOffset RetiredAt,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    IReadOnlyList<string>? TenantDatabases);

/// <summary>A variable whose running value differs from what the configuration, the slot derivation or the profile would set (both masked).</summary>
public sealed record EnvDifference(string Key, string? Expected, string? Actual, string ExpectedFrom);

/// <summary>A running service with its effective environment (exactly what service_env returns) and the differences.</summary>
public sealed record InspectedRunning(string Slot, ServiceEnvResult Service, IReadOnlyList<EnvDifference> Differences);

/// <summary>Everything the status page's configuration inspector shows; secret-looking values are masked with the service_env rules.</summary>
public sealed record ConfigInspection(
    DateTimeOffset LoadedAt,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    DateTimeOffset? FileWrittenAt,
    ConfigView Daemon,
    IReadOnlyList<InspectedService> Services,
    IReadOnlyList<InspectedProfile> Profiles,
    IReadOnlyList<InspectedSlot> Slots,
    IReadOnlyList<InspectedRetiredSlot> RetiredSlots,
    IReadOnlyList<InspectedRunning> Running,
    [property: JsonPropertyName("lanes")] IReadOnlyList<EnvironmentInfo> Environments);

/// <summary>Builds the read-only configuration view of the status page (GET /api/config).</summary>
public static class ConfigInspector
{
    public static async Task<ConfigInspection> BuildAsync(ConfigStore store, StackSupervisor supervisor, SlotOperations operations)
    {
        var config = store.Load();
        var loadedAt = DateTimeOffset.Now;
        DateTimeOffset? written = File.Exists(store.ConfigPath) ? new DateTimeOffset(File.GetLastWriteTime(store.ConfigPath)) : null;

        StackContext? context = null;
        try
        {
            context = ServicePlanner.CreateContext(config, null, null);
        }
        catch (InvalidOperationException)
        {
            // rootPath/defaultCheckout missing: the definitions are shown without resolved folders.
        }

        var services = config.Services.Select(s =>
        {
            string? repo = null, working = null, problem = null;
            if (context != null)
            {
                try
                {
                    var plan = ServicePlanner.Plan(config, context, s.Key, null, new Dictionary<string, string?>());
                    (repo, working) = (plan.RepoPath, plan.WorkingDirectory);
                }
                catch (InvalidOperationException e)
                {
                    problem = e.Message;
                }
            }

            return new InspectedService(ConfigTools.ViewService(s.Key, s.Value), SlotRules.IsExclusive(config, s.Key), repo, working, problem);
        }).ToList();

        var profiles = config.Profiles.Select(p =>
        {
            try
            {
                return new InspectedProfile(p.Key, ProfileResolver.Chain(config, p.Key), ProfileTools.AsWritten(p.Value), ProfileTools.ResolvedView(config, p.Key), null);
            }
            catch (InvalidOperationException e)
            {
                return new InspectedProfile(p.Key, [], ProfileTools.AsWritten(p.Value), null, e.Message);
            }
        }).ToList();

        var slots = new List<InspectedSlot>();
        foreach (var summary in await supervisor.SummariesAsync())
        {
            var slot = new SlotInfo(summary.Name, summary.Index, summary.PortOffset, summary.Prefix);
            var derivation = SlotDeriver.Apply(ProfileResolver.Materialize(config, null, null), slot, SlotDeriver.SlotDirectory(supervisor.StateDirectory, slot));
            var ports = derivation.Config.Services.Where(s => s.Value.Ports.Count > 0).ToDictionary(s => s.Key, s => (IReadOnlyList<int>)s.Value.Ports);
            var state = summary.Running ? "running" : summary.Origin == "created" ? "reserved" : summary.Origin;
            slots.Add(new InspectedSlot(summary.Name, summary.Index, summary.PortOffset, summary.Prefix, state, summary.Origin, ports,
                derivation.Rows.GroupBy(r => r.Id).ToDictionary(g => g.Key, g => SecretMask.Mask(g.Key, g.First().Value)!)));
        }

        var retired = supervisor.State.RetiredSlots()
            .Select(r => new InspectedRetiredSlot(r.Key, r.Value.Name, r.Value.Prefix, r.Value.PortOffset, r.Value.RetiredAt, r.Value.TenantDatabases))
            .OrderBy(r => r.Index).ToList();

        var running = new List<InspectedRunning>();
        foreach (var run in supervisor.Runs)
        {
            var status = await run.StatusAsync(includeLogTail: false, ExternalSnapshot.Empty);
            foreach (var service in status.Services.Where(s => s.Pid > 0 && s.State is not ("exited" or "stopped-for-build")))
            {
                ServiceEnvResult env;
                try
                {
                    env = operations.ServiceEnv(null, run.Slot.IsDefault ? null : run.Slot.Name, service.Name);
                }
                catch (Exception e) when (e is InvalidOperationException or ArgumentException)
                {
                    continue;
                }

                running.Add(new InspectedRunning(run.Slot.Name, env, Differences(config, supervisor, run, service.Name, env)));
            }
        }

        return new ConfigInspection(loadedAt, written, ConfigTools.ViewOf(store.ConfigPath, config, store.WorkspaceInfo), services, profiles, slots, retired, running,
            EnvironmentDiscovery.Discover(config));
    }

    /// <summary>
    ///     What the configuration (global and service environment), the slot's derivation rows and the running profile would set,
    ///     compared with the effective values. Values with placeholders are skipped (they are expanded per start). Both sides are
    ///     masked with the same rules as service_env.
    /// </summary>
    internal static List<EnvDifference> Differences(DevStackConfig config, StackSupervisor supervisor, SlotRun run, string service, ServiceEnvResult env)
    {
        if (env.Source == "unknown" || env.EnvVars.Count == 0)
        {
            return [];
        }

        var expected = new Dictionary<string, (string Value, string From)>(StringComparer.Ordinal);
        void Set(IEnumerable<KeyValuePair<string, string?>> values, string from)
        {
            foreach (var (key, value) in values)
            {
                if (value != null && !value.Contains("${", StringComparison.Ordinal))
                {
                    expected[key] = (value, from);
                }
            }
        }

        Set(config.Environment.Select(e => KeyValuePair.Create(e.Key, (string?)e.Value)), "configuration");
        if (config.Services.TryGetValue(service, out var definition))
        {
            Set(definition.Env.Select(e => KeyValuePair.Create(e.Key, (string?)e.Value)), $"service {service}");
        }

        if (!run.Slot.IsDefault)
        {
            var rows = SlotDeriver.Apply(ProfileResolver.Materialize(config, null, null), run.Slot, run.SlotDirectory).Rows;
            foreach (var row in rows.Where(r => r.Services == null || r.Services.Contains(service)))
            {
                Set(row.Keys.Select(k => KeyValuePair.Create(k, (string?)row.Value)), $"slot {run.Slot.Name} ({row.Id})");
            }
        }

        if (run.Profile is { } profile && config.Profiles.ContainsKey(profile))
        {
            try
            {
                Set(ProfileResolver.Resolve(config, profile, null).Environment, $"profile {profile}");
            }
            catch (InvalidOperationException)
            {
                // A broken profile shows up in the profiles view.
            }
        }

        var actual = env.EnvVars;
        var result = new List<EnvDifference>();
        foreach (var (key, (value, from)) in expected.OrderBy(e => e.Key, StringComparer.Ordinal))
        {
            var masked = SecretMask.Mask(key, value);
            var has = actual.TryGetValue(key, out var current);
            if (!has || !string.Equals(current, masked, StringComparison.Ordinal))
            {
                result.Add(new EnvDifference(key, masked, has ? current : null, from));
            }
        }

        return result;
    }
}
