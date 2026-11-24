using Meshmakers.Octo.DevStack.Configuration;

namespace Meshmakers.Octo.DevStack.Runtime;

/// <summary>
///     The rules a start must keep against the other running slots: no shared port, no shared value of an isolate key
///     (system database, instance prefixes, storage folders), no adapter tenant served twice. A start is admitted under one
///     lock and reserved, so two slots starting at the same time see each other.
/// </summary>
public sealed class SlotValidator(Func<IReadOnlyList<SlotRun>> slots)
{
    private readonly SemaphoreSlim _admission = new(1, 1);

    /// <summary>Refuses ports another slot uses (alive or starting), naming the slot and its service.</summary>
    public void CheckPorts(SlotRun target, IReadOnlyList<(int Port, string Service)> ports)
    {
        foreach (var other in slots().Where(s => s != target))
        {
            var used = other.PortsInUse();
            foreach (var (port, service) in ports)
            {
                if (used.TryGetValue(port, out var holder))
                {
                    throw new InvalidOperationException(
                        $"{target.Qualify(service)} would use port {port}, which {other.Qualify(holder)} of {other.StackLabel()} uses. " +
                        "Stacks must not share ports: stop that service or pick another slot (portOffset).");
                }
            }
        }
    }

    /// <summary>
    ///     The tenants of <paramref name="tenants"/> (tenant -> service) that a service of another active slot serves, with that
    ///     service and its slot: a start of every service leaves those adapters out (<see cref="SlotRun"/>.LeaveOut).
    /// </summary>
    public Dictionary<string, (string Holder, SlotRun Slot)> ServedElsewhere(SlotRun target, IReadOnlyDictionary<string, string> tenants)
    {
        var served = new Dictionary<string, (string, SlotRun)>(StringComparer.OrdinalIgnoreCase);
        foreach (var other in slots().Where(s => s != target && s.Active))
        {
            var theirs = other.Tenants();
            foreach (var tenant in tenants.Keys.Where(t => !served.ContainsKey(t)))
            {
                if (theirs.TryGetValue(tenant, out var holder))
                {
                    served[tenant] = (holder, other);
                }
            }
        }

        return served;
    }

    /// <summary>Checks the planned start against every other slot and reserves it, all under the admission lock.</summary>
    public async Task AdmitAsync(SlotRun target, SlotClaim claim, CancellationToken cancellationToken)
    {
        await _admission.WaitAsync(cancellationToken);
        try
        {
            CheckPorts(target, claim.Ports.Select(p => (p.Key, p.Value)).ToList());
            foreach (var other in slots().Where(s => s != target && s.Active))
            {
                foreach (var (tenant, service) in claim.Tenants)
                {
                    if (other.Tenants().TryGetValue(tenant, out var holder))
                    {
                        throw new InvalidOperationException(
                            $"{target.Qualify(service)} would serve tenant '{tenant}', which {other.Qualify(holder)} of {other.StackLabel()} serves. " +
                            $"A tenant's database is shared by every stack: leave {service} out, or give it another tenant " +
                            $"(overrides={{\"{service}\": {{\"variables\": {{\"tenantId\": \"<another tenant>\"}}}}}}, in a profile settings.meshAdapter.tenantId)." +
                            (target.Slot.IsDefault ? "" : " A lane stack start without a service list leaves such an adapter out by itself."));
                    }
                }

                // Symmetric: the isolate keys of both slots (the default slot has none of its own).
                var keys = new Dictionary<string, IReadOnlyList<string>?>(claim.IsolateKeys, StringComparer.Ordinal);
                foreach (var (key, scope) in other.IsolateKeys())
                {
                    keys.TryAdd(key, scope);
                }

                var mine = IsolationOf(claim, keys, target);
                var theirs = other.IsolationValues(keys);
                foreach (var (key, values) in mine)
                {
                    var shared = values.Intersect(theirs.GetValueOrDefault(key) ?? []).FirstOrDefault();
                    if (shared != null)
                    {
                        throw new InvalidOperationException(
                            $"{key} = '{shared}' in slot '{target.Slot.Name}' is also used by slot '{other.Slot.Name}': two slots would share data. " +
                            "Remove the explicit value (settings or env) so the slot derives its own, or stop the other slot.");
                    }
                }
            }

            target.Reserve(claim);
        }
        finally
        {
            _admission.Release();
        }
    }

    /// <summary>The planned values for the keys; keys the claim does not cover come from the services already running in the slot.</summary>
    private static Dictionary<string, HashSet<string>> IsolationOf(SlotClaim claim, IReadOnlyDictionary<string, IReadOnlyList<string>?> keys, SlotRun target)
    {
        var result = target.IsolationValues(keys);
        foreach (var (key, planned) in claim.Values(keys))
        {
            result[key].UnionWith(planned);
        }

        return result;
    }

    /// <summary>
    ///     A slot's isolated values must not be the default slot's data names: not the configured value (e.g. OctoSystem) and
    ///     not unset (the service default, which the default slot uses).
    /// </summary>
    public static void CheckAgainstDefault(SlotInfo slot, DevStackConfig config, SlotClaim claim)
    {
        foreach (var (key, values) in claim.Isolation)
        {
            if (values.Contains(SlotRun.Unset))
            {
                throw new InvalidOperationException(
                    $"{key} is unset in slot '{slot.Name}' (an explicit null removed it), so its services would use the shared stack's data. Remove the null.");
            }

            if (config.Environment.TryGetValue(key, out var configured) && values.Contains(configured))
            {
                throw new InvalidOperationException(
                    $"{key} = '{configured}' in slot '{slot.Name}' is the shared stack's value: the stack would share its data. Remove the explicit value.");
            }
        }
    }
}
