using System.Text.RegularExpressions;

namespace Meshmakers.Octo.DevStack.Configuration;

/// <summary>
///     The static slot rules: names, the slots of devstack.yaml (index, offset, prefix, disjoint ports) and what a start in
///     another slot may not contain (frontends, the HTTP activator). The rules that need the running slots are in
///     Runtime/SlotValidator.
/// </summary>
public static partial class SlotRules
{
    /// <summary>Host ports of the kind infrastructure and the local S3 store; no shifted service port may land on one.</summary>
    public static readonly int[] InfraPorts = [27017, 5672, 15672, 4301, 8333];

    [GeneratedRegex("^[a-z0-9-]+$")]
    private static partial Regex NameRegex();

    [GeneratedRegex("^[a-z][a-z0-9_]*$")]
    private static partial Regex PrefixRegex();

    public static bool IsValidName(string? name) => name == SlotInfo.DefaultName || (!string.IsNullOrEmpty(name) && NameRegex().IsMatch(name));

    public static string NameRule(string? name) =>
        $"Invalid slot name '{name}': lowercase letters, digits and '-' (e.g. 'second'), or 'default'.";

    /// <summary>The slot of a definition in devstack.yaml with its defaults (offset 100 * index, prefix s&lt;index&gt;).</summary>
    public static SlotInfo Effective(string name, SlotDefinition definition) =>
        new(name, definition.Index, definition.PortOffset ?? 100 * definition.Index, definition.Prefix ?? $"s{definition.Index}");

    /// <summary>A slot that is not in devstack.yaml, created with <paramref name="index"/>.</summary>
    public static SlotInfo Created(string name, int index) => new(name, index, 100 * index, $"s{index}");

    /// <summary>Whether a service runs in the default slot only: its own flag, else the built-in service of that name.</summary>
    public static bool IsExclusive(DevStackConfig config, string service)
    {
        if (config.Services.TryGetValue(service, out var s) && s.Exclusive is { } own)
        {
            return own;
        }

        return ConfigStore.BuiltIn.Services.TryGetValue(service, out var builtIn) && builtIn.Exclusive == true;
    }

    /// <summary>What a start in a non-default slot may not do. Throws naming the rule.</summary>
    public static void CheckSpec(DevStackConfig materialized, string slot, IReadOnlyList<string> services, StartSpec spec,
        IReadOnlyDictionary<string, string?> env)
    {
        var exclusive = services.Where(n => IsExclusive(materialized, n)).ToList();
        if (exclusive.Count > 0)
        {
            throw new InvalidOperationException(
                $"{string.Join(", ", exclusive)} run(s) in the shared stack only (fixed ports, redirect URIs and cookies of the frontends); " +
                $"leave them out of slot '{slot}'.");
        }

        if (spec.Settings?.HttpActivator is { } activator && (activator.Enabled == true || activator.AddressTemplate != null))
        {
            throw new InvalidOperationException(
                $"settings.httpActivator applies to the workloads of the kind cluster, which only the shared stack serves; remove it from slot '{slot}'.");
        }

        if (env.TryGetValue("OCTO_COMMUNICATIONCONTROLLER__ACTIVATORENABLED", out var on) && string.Equals(on, "true", StringComparison.OrdinalIgnoreCase))
        {
            throw new InvalidOperationException(
                $"OCTO_COMMUNICATIONCONTROLLER__ACTIVATORENABLED=true (the HTTP activator for workloads) is for the shared stack only, not slot '{slot}'.");
        }
    }

    /// <summary>Checks the slots of devstack.yaml: names, indices, offsets, prefixes, and that no shifted port meets another.</summary>
    public static void ValidateSlots(DevStackConfig config, string source)
    {
        var slots = new List<SlotInfo>();
        foreach (var (name, definition) in config.Slots)
        {
            if (definition == null)
            {
                throw new InvalidOperationException($"{source}: slot '{name}' needs an index.");
            }

            if (name == SlotInfo.DefaultName || !NameRegex().IsMatch(name))
            {
                throw new InvalidOperationException($"{source}: slot '{name}': lowercase letters, digits and '-', and not 'default'.");
            }

            if (definition.Index < 1)
            {
                throw new InvalidOperationException($"{source}: slot '{name}': index must be 1 or more (0 is the shared stack).");
            }

            var slot = Effective(name, definition);
            if (slot.PortOffset <= 0)
            {
                throw new InvalidOperationException($"{source}: slot '{name}': portOffset must be positive.");
            }

            if (!PrefixRegex().IsMatch(slot.Prefix))
            {
                throw new InvalidOperationException($"{source}: slot '{name}': prefix '{slot.Prefix}' must start with a letter (a-z, 0-9, _); it names databases and schemas.");
            }

            slots.Add(slot);
        }

        foreach (var slot in slots)
        {
            var other = slots.FirstOrDefault(s => s != slot && (s.Index == slot.Index || s.PortOffset == slot.PortOffset || s.Prefix == slot.Prefix));
            if (other != null)
            {
                throw new InvalidOperationException($"{source}: slots '{slot.Name}' and '{other.Name}' share an index, port offset or prefix.");
            }
        }

        CheckPortsDisjoint(config, slots.Prepend(SlotInfo.Default).ToList(), source);
    }

    /// <summary>The shifted ports of every slot are disjoint from each other and from the kind infrastructure.</summary>
    public static void CheckPortsDisjoint(DevStackConfig config, IReadOnlyList<SlotInfo> slots, string source)
    {
        var owners = new Dictionary<int, string>();
        foreach (var slot in slots)
        {
            foreach (var (name, service) in config.Services)
            {
                if (!slot.IsDefault && IsExclusive(config, name))
                {
                    continue;
                }

                foreach (var port in service.Ports.Select(p => p + slot.PortOffset))
                {
                    if (!slot.IsDefault && InfraPorts.Contains(port))
                    {
                        throw new InvalidOperationException($"{source}: slot '{slot.Name}' moves {name} onto port {port} of the kind infrastructure; pick another portOffset.");
                    }

                    var owner = $"{name} in slot '{slot.Name}'";
                    if (owners.TryGetValue(port, out var other) && !other.EndsWith($"slot '{slot.Name}'", StringComparison.Ordinal))
                    {
                        throw new InvalidOperationException($"{source}: port {port} of {owner} is also port of {other}; pick another portOffset.");
                    }

                    owners.TryAdd(port, owner);
                }
            }
        }
    }
}
