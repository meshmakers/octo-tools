using Meshmakers.Octo.DevStack.Configuration;

namespace Meshmakers.Octo.DevStack.Runtime;

/// <summary>
///     Which slots exist: the default slot, the slots of devstack.yaml, and slots created on first use (their index is kept
///     in the state file). A new slot gets the lowest index that is neither in use nor retired.
/// </summary>
public sealed class SlotRegistry(ConfigStore store, StateStore state)
{
    private readonly Lock _lock = new();

    /// <summary>Every known slot: default, configured, created (by index).</summary>
    public List<(SlotInfo Slot, string Origin)> Known()
    {
        var config = store.Load();
        var result = new List<(SlotInfo, string)> { (SlotInfo.Default, "default") };
        result.AddRange(config.Slots.Select(s => (SlotRules.Effective(s.Key, s.Value), "config")));
        foreach (var (name, index) in state.SlotIndices())
        {
            if (!config.Slots.ContainsKey(name) && name != SlotInfo.DefaultName)
            {
                result.Add((SlotRules.Created(name, index), "created"));
            }
        }

        return result.OrderBy(r => r.Item1.Index).ToList();
    }

    /// <summary>The slot of a name; an unknown name is created with the next free index when <paramref name="create"/> is set.</summary>
    public SlotInfo Resolve(string name, bool create)
    {
        if (!SlotRules.IsValidName(name))
        {
            throw new InvalidOperationException(SlotRules.NameRule(name));
        }

        lock (_lock)
        {
            var known = Known();
            var found = known.FirstOrDefault(k => k.Slot.Name == name).Slot;
            if (found != null)
            {
                return found;
            }

            if (!create)
            {
                throw new InvalidOperationException(
                    $"Unknown slot '{name}'. Known: {string.Join(", ", known.Select(k => k.Slot.Name))}; " +
                    (Discovery.EnvironmentDiscovery.Discover(store.Load()).FirstOrDefault(e => e.Problem == null && e.Slot == name) is { } env
                        ? $"it is the stack of lane '{env.Name}', which has not been started: stack_start(owner, lane=\"{env.Name}\") starts it."
                        : $"stack_start(slot=\"{name}\") creates it."));
            }

            var candidate = NextLocked(name, known);
            state.SaveSlotIndex(name, candidate.Index);
            return candidate;
        }
    }

    /// <summary>
    ///     The slot <paramref name="name"/> has, or would get if it were created now (nothing is reserved): lane_list shows it
    ///     for environments not started yet.
    /// </summary>
    public (SlotInfo Slot, bool Exists) Predict(string name)
    {
        lock (_lock)
        {
            var known = Known();
            var found = known.FirstOrDefault(k => k.Slot.Name == name).Slot;
            return found != null ? (found, true) : (NextLocked(name, known), false);
        }
    }

    /// <summary>
    ///     The lowest index that is neither in use nor retired and whose shifted
    ///     ports collide with nothing: ports shift by the index, so reusing low indices keeps them away from kind and other
    ///     ports. A retired index (a removed slot whose data may remain) is never handed out - a new slot would find that data -
    ///     until admin_slot_forget un-retires it. An index whose ports collide (a configured service, a configured slot, the kind
    ///     infrastructure) is skipped (AB#9676: with the default configuration index 7 moves voestApp 4300 onto 5000 and index 8
    ///     meets slot 'second'); only when no index fits below the highest port the call is refused.
    /// </summary>
    private SlotInfo NextLocked(string name, List<(SlotInfo Slot, string Origin)> known)
    {
        var config = store.Load();
        var retired = state.RetiredSlots();
        var highest = config.Services.Values.SelectMany(s => s.Ports).DefaultIfEmpty(0).Max();
        string? lastCollision = null;
        for (var index = 1; highest + SlotRules.Created(name, index).PortOffset <= 65535; index++)
        {
            var candidate = SlotRules.Created(name, index);
            var taken = known.Any(k => k.Slot.Index == index || k.Slot.PortOffset == candidate.PortOffset || k.Slot.Prefix == candidate.Prefix) ||
                        retired.ContainsKey(index) ||
                        retired.Values.Any(r => r.PortOffset == candidate.PortOffset || r.Prefix == candidate.Prefix);
            if (taken)
            {
                continue;
            }

            try
            {
                SlotRules.CheckPortsDisjoint(config, known.Select(k => k.Slot).Append(candidate).ToList(), "slot");
                return candidate;
            }
            catch (InvalidOperationException e)
            {
                lastCollision = e.Message;
            }
        }

        throw new InvalidOperationException($"No free slot index for '{name}': every index up to the highest port is in use, retired or collides" +
                                            (lastCollision != null ? $" (last: {lastCollision})" : "") + ". admin_slot_drop_data frees retired indices.");
    }
}
