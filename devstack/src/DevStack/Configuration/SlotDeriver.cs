using System.Globalization;
using System.Text.RegularExpressions;

namespace Meshmakers.Octo.DevStack.Configuration;

/// <summary>A rendered derivation row of a slot (what stack_list and the tests show).</summary>
public sealed record SlotDerivedRow(string Id, IReadOnlyList<string> Keys, string Value, IReadOnlyList<string>? Services, bool Isolate);

/// <summary>
///     What a slot changes in a start: <see cref="Config"/> is the materialized configuration with every port shifted and the
///     service-scoped rows in the services' env; <see cref="Env"/> holds the stack-wide rows (merged after the env providers and
///     before the settings fan-out, so explicit settings and profile env win).
/// </summary>
public sealed record SlotDerivation(
    SlotInfo Slot,
    DevStackConfig Config,
    IReadOnlyDictionary<string, string> Env,
    IReadOnlyList<SlotDerivedRow> Rows,
    IReadOnlyList<string> Skipped)
{
    /// <summary>Environment keys of isolate rows, with the services they apply to (null: every service of the start).</summary>
    public IReadOnlyDictionary<string, IReadOnlyList<string>?> IsolateKeys =>
        Rows.Where(r => r.Isolate).SelectMany(r => r.Keys.Select(k => (k, r.Services))).GroupBy(x => x.k)
            .ToDictionary(g => g.Key, g => g.First().Services);
}

/// <summary>
///     Derives the values of a non-default slot from the table in devstack.yaml (slotDerivations): shifted ports and the
///     environment rows. The default slot gets nothing - its plans equal the ones without slots, bit for bit.
/// </summary>
public static partial class SlotDeriver
{
    // Not after '$': ${repoPath} and the like are the service placeholders, expanded when the service is planned.
    [GeneratedRegex(@"(?<!\$)\{([A-Za-z0-9_.:\-]+)\}")]
    private static partial Regex PlaceholderRegex();

    [GeneratedRegex(@"^\s*slot\.(index|offset|name|prefix)\s*(==|!=|>=|<=|>|<)\s*(\S+)\s*$")]
    private static partial Regex WhenRegex();

    [GeneratedRegex(@"(?<=:)(\d{2,5})(?=$|[/;,\s""'])")]
    private static partial Regex PortRegex();

    [GeneratedRegex(@"^(https?)://[^:/;]+:(\d+)", RegexOptions.IgnoreCase)]
    private static partial Regex UrlPortRegex();

    /// <summary>The folder of a slot's generated files (identity overlay, octo-cli installation): &lt;state&gt;/slots/&lt;name&gt;.</summary>
    public static string SlotDirectory(string stateDirectory, SlotInfo slot) => Path.Combine(stateDirectory, "slots", slot.Name);

    /// <summary>
    ///     Applies a slot to a materialized configuration. <paramref name="instances"/> lets scoped rows reach the instances
    ///     of a scoped service; <paramref name="explicitEnv"/> (settings fan-out and spec env) is never overwritten by a scoped row.
    /// </summary>
    public static SlotDerivation Apply(DevStackConfig materialized, SlotInfo slot, string slotDir,
        IReadOnlyDictionary<string, ProfileInstance>? instances = null, IReadOnlyDictionary<string, string?>? explicitEnv = null)
    {
        if (slot.IsDefault)
        {
            return new SlotDerivation(slot, materialized, new Dictionary<string, string>(), [], []);
        }

        var table = materialized.EffectiveSlotDerivations;
        var config = table.PortShift == false ? CloneServices(materialized) : ShiftPorts(materialized, slot.PortOffset);
        ApplySlotVariants(config, slot, slotDir);
        var env = new Dictionary<string, string>(StringComparer.Ordinal);
        var rows = new List<SlotDerivedRow>();
        var skipped = new List<string>();
        foreach (var row in table.Rows.Where(r => !r.Disabled))
        {
            if (!When(row.When, slot))
            {
                continue;
            }

            var keys = ExpandKeys(row.Keys).ToList();
            try
            {
                if (row.Services is { Count: > 0 } scope)
                {
                    var targets = config.Services.Keys
                        .Where(n => scope.Contains(n) || (instances?.TryGetValue(n, out var i) == true && i.Of != null && scope.Contains(i.Of)))
                        .ToList();
                    string? shown = null;
                    foreach (var name in targets)
                    {
                        var value = Render(row.Value, config, slot, slotDir, name);
                        shown ??= value;
                        var service = config.Services[name];
                        foreach (var key in keys.Where(k => explicitEnv?.ContainsKey(k) != true && !service.Env.ContainsKey(k)))
                        {
                            service.Env[key] = value;
                        }
                    }

                    rows.Add(new SlotDerivedRow(row.Id, keys, shown ?? Render(row.Value, config, slot, slotDir, scope[0]), targets, row.Isolate));
                }
                else
                {
                    var value = Render(row.Value, config, slot, slotDir);
                    foreach (var key in keys)
                    {
                        env[key] = value;
                    }

                    rows.Add(new SlotDerivedRow(row.Id, keys, value, null, row.Isolate));
                }
            }
            catch (NotApplicableException e)
            {
                // A row naming a service this config does not have (removed by the developer) has nothing to point to.
                skipped.Add($"{row.Id}: {e.Message}");
            }
        }

        return new SlotDerivation(slot, config, env, rows, skipped);
    }

    /// <summary>The folder of a service's generated files in a slot: &lt;slotDir&gt;/services/&lt;service&gt;.</summary>
    public static string FilesDirectory(string slotDir, string service) => Path.Combine(slotDir, "services", service);

    /// <summary>
    ///     Replaces the start of every service that has a slot variant (<see cref="ServiceConfig.Slot"/>) with it, rendered
    ///     for the slot. A variant naming a service that is not configured leaves the service as it is.
    /// </summary>
    private static void ApplySlotVariants(DevStackConfig shifted, SlotInfo slot, string slotDir)
    {
        foreach (var (name, service) in shifted.Services)
        {
            if (service.Slot is not { } variant)
            {
                continue;
            }

            string R(string template) => Render(template, shifted, slot, slotDir, name);
            try
            {
                var command = variant.Command == null ? null : R(variant.Command);
                var args = variant.Args?.Select(R).ToList();
                var workingDirectory = variant.WorkingDirectory == null ? null : R(variant.WorkingDirectory);
                var healthUrl = variant.HealthUrl == null ? null : R(variant.HealthUrl);
                var env = variant.Env?.ToDictionary(e => e.Key, e => R(e.Value));
                service.Command = command ?? service.Command;
                service.Args = args ?? service.Args;
                service.WorkingDirectory = workingDirectory ?? service.WorkingDirectory;
                service.HealthUrl = healthUrl ?? service.HealthUrl;
                foreach (var (key, value) in env ?? [])
                {
                    service.Env[key] = value;
                }
            }
            catch (NotApplicableException)
            {
                // The variant points to a service the developer removed: the service starts as in the default slot.
            }
        }
    }

    /// <summary>Expands "@name" entries into the shared key lists of <see cref="SettingsMap.KeyLists"/>.</summary>
    public static IEnumerable<string> ExpandKeys(IEnumerable<string> keys)
    {
        foreach (var key in keys)
        {
            if (key.StartsWith('@'))
            {
                if (!SettingsMap.KeyLists.TryGetValue(key[1..], out var list))
                {
                    throw new InvalidOperationException($"Unknown key list '{key}'. Known: {string.Join(", ", SettingsMap.KeyLists.Keys.Select(k => "@" + k))}.");
                }

                foreach (var k in list)
                {
                    yield return k;
                }
            }
            else
            {
                yield return key;
            }
        }
    }

    /// <summary>Evaluates a row condition such as "slot.index > 1"; null is true (every non-default slot).</summary>
    public static bool When(string? condition, SlotInfo slot)
    {
        if (string.IsNullOrWhiteSpace(condition))
        {
            return true;
        }

        var match = WhenRegex().Match(condition);
        if (!match.Success)
        {
            throw new InvalidOperationException(
                $"Invalid condition '{condition}'. Use slot.index|offset|name|prefix with ==, !=, >, >=, < or <=, e.g. 'slot.index > 1'.");
        }

        var field = match.Groups[1].Value;
        var op = match.Groups[2].Value;
        var right = match.Groups[3].Value.Trim('"', '\'');
        if (field is "index" or "offset")
        {
            if (!int.TryParse(right, NumberStyles.Integer, CultureInfo.InvariantCulture, out var number))
            {
                throw new InvalidOperationException($"Invalid condition '{condition}': '{right}' is no number.");
            }

            var left = field == "index" ? slot.Index : slot.PortOffset;
            return op switch
            {
                "==" => left == number,
                "!=" => left != number,
                ">" => left > number,
                ">=" => left >= number,
                "<" => left < number,
                _ => left <= number
            };
        }

        var text = field == "name" ? slot.Name : slot.Prefix;
        return op switch
        {
            "==" => text == right,
            "!=" => text != right,
            _ => throw new InvalidOperationException($"Invalid condition '{condition}': slot.{field} supports == and != only.")
        };
    }

    /// <summary>Renders one row value. Placeholders: slot.name/index/prefix/offset, slotDir, service, port.&lt;service&gt;.&lt;n|https|http&gt;, shift:&lt;port&gt;.</summary>
    public static string Render(string template, DevStackConfig shifted, SlotInfo slot, string slotDir, string? service = null) =>
        PlaceholderRegex().Replace(template, match =>
        {
            var name = match.Groups[1].Value;
            switch (name)
            {
                case "slot.name":
                    return slot.Name;
                case "slot.index":
                    return slot.Index.ToString(CultureInfo.InvariantCulture);
                case "slot.prefix":
                    return slot.Prefix;
                case "slot.offset":
                    return slot.PortOffset.ToString(CultureInfo.InvariantCulture);
                case "slotDir":
                    return slotDir;
                case "filesDir":
                    return FilesDirectory(slotDir, service ?? throw new InvalidOperationException($"{{filesDir}} in '{template}' belongs to a service."));
                case "service":
                    return service ?? throw new InvalidOperationException($"{{service}} in '{template}' needs a row with 'services'.");
            }

            if (name.StartsWith("shift:", StringComparison.Ordinal) &&
                int.TryParse(name[6..], NumberStyles.Integer, CultureInfo.InvariantCulture, out var basePort))
            {
                return (basePort + slot.PortOffset).ToString(CultureInfo.InvariantCulture);
            }

            if (name.StartsWith("port.", StringComparison.Ordinal))
            {
                var parts = name.Split('.');
                if (parts.Length == 3)
                {
                    return Port(shifted, parts[1], parts[2]).ToString(CultureInfo.InvariantCulture);
                }
            }

            throw new InvalidOperationException(
                $"Unknown placeholder '{{{name}}}' in '{template}'. Known: slot.name, slot.index, slot.prefix, slot.offset, slotDir, filesDir, service, " +
                "port.<service>.<n|https|http>, shift:<port>.");
        });

    /// <summary>A port of a service: its n-th configured port, or the https/http port of its --urls argument (else the first/second port).</summary>
    public static int Port(DevStackConfig config, string serviceName, string which)
    {
        if (!config.Services.TryGetValue(serviceName, out var service))
        {
            throw new NotApplicableException($"no service '{serviceName}' is configured");
        }

        if (int.TryParse(which, NumberStyles.Integer, CultureInfo.InvariantCulture, out var index))
        {
            return index >= 0 && index < service.Ports.Count
                ? service.Ports[index]
                : throw new NotApplicableException($"service '{serviceName}' has no port #{index}");
        }

        if (which is not ("https" or "http"))
        {
            throw new InvalidOperationException($"port.{serviceName}.{which}: use a port index, 'https' or 'http'.");
        }

        foreach (var url in UrlsOf(service))
        {
            var m = UrlPortRegex().Match(url);
            if (m.Success && string.Equals(m.Groups[1].Value, which, StringComparison.OrdinalIgnoreCase))
            {
                return int.Parse(m.Groups[2].Value, CultureInfo.InvariantCulture);
            }
        }

        var fallback = which == "https" ? 0 : 1;
        return service.Ports.Count > fallback
            ? service.Ports[fallback]
            : throw new NotApplicableException($"service '{serviceName}' has no {which} port");
    }

    private static IEnumerable<string> UrlsOf(ServiceConfig service)
    {
        // The last --urls wins (an instance appends its own in extraArgs).
        var value = service.Args.LastOrDefault(a => a.StartsWith("--urls=", StringComparison.Ordinal))?["--urls=".Length..];
        if (value == null)
        {
            var index = service.Args.FindLastIndex(a => a == "--urls");
            value = index >= 0 && index + 1 < service.Args.Count ? service.Args[index + 1] : null;
        }

        return value?.Split(';', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries) ?? [];
    }

    /// <summary>
    ///     A copy of the configuration with every service's ports, health URL, the ports of its --urls arguments and its
    ///     announced URLs moved by <paramref name="offset"/> (announced and health URLs only where the port is a service port).
    /// </summary>
    public static DevStackConfig ShiftPorts(DevStackConfig config, int offset)
    {
        var copy = CloneServices(config);
        if (offset == 0)
        {
            return copy;
        }

        var servicePorts = config.Services.Values.SelectMany(s => s.Ports).ToHashSet();
        foreach (var service in copy.Services.Values)
        {
            service.Ports = service.Ports.Select(p => p + offset).ToList();
            service.HealthUrl = service.HealthUrl == null ? null : ShiftKnown(service.HealthUrl, servicePorts, offset);
            for (var i = 0; i < service.Args.Count; i++)
            {
                if (service.Args[i].StartsWith("--urls=", StringComparison.Ordinal) || (i > 0 && service.Args[i - 1] == "--urls"))
                {
                    service.Args[i] = PortRegex().Replace(service.Args[i], m => (int.Parse(m.Value, CultureInfo.InvariantCulture) + offset).ToString(CultureInfo.InvariantCulture));
                }
            }

            service.AnnounceEnv = service.AnnounceEnv.ToDictionary(kv => kv.Key, kv => ShiftKnown(kv.Value, servicePorts, offset));
        }

        return copy;
    }

    private static string ShiftKnown(string text, HashSet<int> ports, int offset) =>
        PortRegex().Replace(text, m =>
        {
            var port = int.Parse(m.Value, CultureInfo.InvariantCulture);
            return ports.Contains(port) ? (port + offset).ToString(CultureInfo.InvariantCulture) : m.Value;
        });

    private static DevStackConfig CloneServices(DevStackConfig config) => new()
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
        EnvProviders = config.EnvProviders,
        Profiles = config.Profiles,
        Slots = config.Slots,
        SlotOptions = config.SlotOptions,
        SlotDerivations = config.SlotDerivations,
        EffectiveSlotDerivations = config.EffectiveSlotDerivations,
        Services = config.Services.ToDictionary(s => s.Key, s => s.Value.Clone())
    };

    /// <summary>The built-in table with the user's rows merged by id (a user row replaces, <c>disabled: true</c> removes).</summary>
    public static SlotDerivationConfig MergeTables(SlotDerivationConfig? builtIn, SlotDerivationConfig? user)
    {
        var rows = (builtIn?.Rows ?? []).ToList();
        foreach (var row in user?.Rows ?? [])
        {
            var index = rows.FindIndex(r => r.Id == row.Id);
            if (index >= 0)
            {
                rows[index] = row;
            }
            else
            {
                rows.Add(row);
            }
        }

        return new SlotDerivationConfig
        {
            PortShift = user?.PortShift ?? builtIn?.PortShift ?? true,
            Rows = rows.Where(r => !r.Disabled).ToList()
        };
    }

    /// <summary>Checks the table: ids, keys, conditions, placeholders (rendered for a probe slot).</summary>
    public static void ValidateTable(DevStackConfig config, string source)
    {
        var ids = new HashSet<string>(StringComparer.Ordinal);
        var probe = new SlotInfo("probe", 1, 100, "s1");
        var shifted = ShiftPorts(config, probe.PortOffset);
        foreach (var row in config.EffectiveSlotDerivations.Rows)
        {
            try
            {
                if (string.IsNullOrWhiteSpace(row.Id))
                {
                    throw new InvalidOperationException("a row has no id.");
                }

                if (!ids.Add(row.Id))
                {
                    throw new InvalidOperationException("the id is used twice.");
                }

                if (row.Keys.Count == 0)
                {
                    throw new InvalidOperationException("no keys.");
                }

                _ = ExpandKeys(row.Keys).ToList();
                When(row.When, probe);
                // A scope or placeholder naming a service this file does not configure (removed by the developer) is skipped.
                try
                {
                    Render(row.Value, shifted, probe, "/slots/probe", row.Services is { Count: > 0 } s ? s[0] : null);
                }
                catch (NotApplicableException)
                {
                    // Rows pointing to a service the developer removed are skipped at start.
                }
            }
            catch (InvalidOperationException e)
            {
                throw new InvalidOperationException($"{source}: slotDerivations row '{row.Id}': {e.Message}", e);
            }
        }
    }

    /// <summary>A placeholder names a service (or a port of one) that is not configured: the row has nothing to point to.</summary>
    public sealed class NotApplicableException(string message) : InvalidOperationException(message);
}
