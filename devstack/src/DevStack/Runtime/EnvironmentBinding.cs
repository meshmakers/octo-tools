using Meshmakers.Octo.DevStack.Common;
using Meshmakers.Octo.DevStack.Configuration;
using Meshmakers.Octo.DevStack.Discovery;

namespace Meshmakers.Octo.DevStack.Runtime;

/// <summary>What an <c>env</c> argument resolves to: the environment's slot, its folder (the checkout) and the lease holder.</summary>
public sealed record EnvironmentScope(EnvironmentInfo Environment, string Slot, string Checkout, string LeaseOwner)
{
    public string Name => Environment.Name;
}

/// <summary>
///     Binds a feature environment to its stack slot: the slot is named after the environment (manifest "slot"), created on
///     the first start with the next free index, and its lease is held by the environment ("env:&lt;name&gt;") so every session
///     of the feature shares it. The calling session's owner is kept for audit in the lease purpose and the daemon log.
/// </summary>
public static class EnvironmentBinding
{
    /// <summary>
    ///     The scope of <paramref name="env"/>, or null without one. A slot or checkout given next to it must be the
    ///     environment's own.
    /// </summary>
    public static EnvironmentScope? Resolve(DevStackConfig config, string? env, string? slot = null, string? checkout = null)
    {
        if (string.IsNullOrWhiteSpace(env))
        {
            return null;
        }

        var info = EnvironmentDiscovery.Find(config, env.Trim());
        if (slot != null && slot != info.Slot)
        {
            throw new ArgumentException($"Lane '{info.Name}' runs in slot '{info.Slot}', not '{slot}'; leave slot out when you pass lane.");
        }

        if (checkout != null)
        {
            var root = ServicePlanner.RootPath(config);
            string resolved;
            try
            {
                resolved = ServicePlanner.ResolveFolder(checkout, root, null, "base lane");
            }
            catch (InvalidOperationException)
            {
                resolved = checkout;
            }

            if (!PathScope.SamePath(resolved, info.Path))
            {
                throw new ArgumentException($"Lane '{info.Name}' is the folder {info.Path}, not '{checkout}'; leave the base lane out when you pass lane.");
            }
        }

        return new EnvironmentScope(info, info.Slot, info.Path, info.LeaseOwner);
    }

    /// <summary>The lease purpose that records which session acted for the environment last.</summary>
    public static string Purpose(EnvironmentScope scope, string owner) => $"lane {scope.Name}; last change by {owner}";

    /// <summary>
    ///     Takes or renews the environment's lease of its slot for a changing call of <paramref name="owner"/>; refused when
    ///     another holder (a session that used the slot without env) has it.
    /// </summary>
    /// <param name="forRemoval">lane_remove's own claim: the lane's removal mark is its own.</param>
    public static void Claim(StackSupervisor supervisor, EnvironmentScope scope, string owner, bool forRemoval = false)
    {
        if (string.IsNullOrWhiteSpace(owner))
        {
            throw new ArgumentException("owner is required (it is recorded for audit; the lane holds the lease).");
        }

        if (!forRemoval)
        {
            supervisor.Removals.Refuse(scope.Name); // AB#9673: nothing new starts on a lane that is being removed
        }

        supervisor.Leases.Get(scope.Slot).Require(scope.LeaseOwner, Purpose(scope, owner.Trim()));
    }

    /// <summary>The environment whose slot is <paramref name="slot"/>, or null.</summary>
    public static EnvironmentInfo? OfSlot(DevStackConfig config, string slot) =>
        slot == SlotInfo.DefaultName ? null : EnvironmentDiscovery.Discover(config).FirstOrDefault(e => e.Problem == null && e.Slot == slot);
}
