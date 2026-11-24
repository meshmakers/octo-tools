using System.ComponentModel;
using Meshmakers.Octo.DevStack.Configuration;
using Meshmakers.Octo.DevStack.Discovery;
using Meshmakers.Octo.DevStack.Leasing;
using ModelContextProtocol.Server;

namespace Meshmakers.Octo.DevStack.Tools;

public sealed record LeaseAcquireResult(bool Granted, LeaseInfo? Lease, LeaseSnapshot State);

/// <summary>
///     lease_release: whether a lease was released, whose it was (formerHolder: owner, session, purpose), who holds it now
///     (holder: the first waiter, which got it at once; null when it is free) and who still waits.
/// </summary>
public sealed record LeaseReleaseResult(bool Released, LeaseInfo? FormerHolder, LeaseInfo? Holder, IReadOnlyList<LeaseWaiterInfo> Queue, string Note);

/// <summary>Who owns the shared stack (and the other stacks).</summary>
[McpServerToolType]
public sealed class LeaseTools(LeaseRegistry leases, ConfigStore store)
{
    private LeaseManager Of(string? slot)
    {
        if (slot != null && !SlotRules.IsValidName(slot))
        {
            throw new ArgumentException(SlotRules.NameRule(slot));
        }

        return slot == null ? leases.Default : leases.Get(slot);
    }

    private const string SlotDescription = "Diagnostics only: the lease of a stack slot that belongs to no lane (stack_list). Default: the shared stack.";

    [McpServerTool(Name = "lease_status", ReadOnly = true)]
    [Description("Shows who holds the lease of the shared stack (owner, session, purpose, since, expiry) and who waits for it; lane=<name> shows " +
                 "the lease of that lane's stack instead (held by 'lane:<name>' - the purpose names the owner and the session that changed it " +
                 "last). holder.lastActivityAt (local time) is the holder's last changing call (or the end of a build that pinned the lease) " +
                 "and holder.idleMinutes how long it has been idle since: the lease expires ttlMinutes (default 30) after that activity. Check " +
                 "it before changing the shared stack; message the holder's session to ask for it. Read-only.")]
    public LeaseSnapshot Status(
        [Description("A lane (lane_list): the lease of its stack.")] string? lane = null,
        [Description(SlotDescription)] string? slot = null) =>
        ToolGuard.Run(() => Of(string.IsNullOrWhiteSpace(lane) ? slot : EnvironmentDiscovery.Find(store.Load(), lane.Trim()).Slot).Snapshot());

    [McpServerTool(Name = "lease_acquire")]
    [Description("Takes the shared stack's lease before a series of changes there (stack_start/stop, service_*, base_build kind=range/all, builds " +
                 "with stopServices), optionally waiting in a first-come-first-served queue (waitSeconds, max 900). Changing calls also take a " +
                 "free lease implicitly; every changing call of the holder renews it, and it expires ttlMinutes (default 30) after the holder's " +
                 "last activity. Release it with lease_release when you are done. A lane's " +
                 "stack has its own lease that belongs to the lane ('lane:<name>', shared by every session of the lane): a session gets it by " +
                 "passing lane=<name> to stack_*, service_*, lane_build or lane_test, not with lease_acquire.")]
    public Task<LeaseAcquireResult> Acquire(
        [Description(StackTools.OwnerDescription)] string owner,
        [Description(StackTools.SessionDescription)] string? session = null,
        [Description("What you need the stack for, shown to waiting sessions, e.g. 'AB#8625 verify enum null handling'.")] string? purpose = null,
        [Description("Idle timeout in minutes, 5-720 (default 30): the lease expires that long after your last changing call; every changing call " +
                     "renews it.")] int ttlMinutes = 30,
        [Description("Seconds to wait in the queue if someone else holds it (0 = do not wait, max 900).")] int waitSeconds = 0,
        [Description(SlotDescription)] string? slot = null,
        CancellationToken cancellationToken = default) =>
        ToolGuard.Run(async () =>
        {
            var lease = Of(slot);
            var granted = await lease.AcquireAsync(owner, purpose, TimeSpan.FromMinutes(Math.Clamp(ttlMinutes, 5, 720)),
                TimeSpan.FromSeconds(Math.Clamp(waitSeconds, 0, 900)), cancellationToken, session);
            return new LeaseAcquireResult(granted != null, granted, lease.Snapshot());
        });

    [McpServerTool(Name = "lease_release")]
    [Description("Releases the shared stack's lease; the first waiting session gets it at once. The stack keeps running. The answer says " +
                 "whether a lease was released (released), whose it was (formerHolder: owner, session), who holds it now (holder: the waiter that " +
                 "got it; null = free) and who still waits. force=true releases a lease held by another session - ONLY when the developer said so. " +
                 "A lane's lease ('lane:<name>') is released by lane_remove.")]
    public LeaseReleaseResult Release(
        [Description(StackTools.OwnerDescription)] string owner,
        [Description("Release even if another session holds it (only on the developer's go).")] bool force = false,
        [Description(StackTools.SessionDescription)] string? session = null,
        [Description(SlotDescription)] string? slot = null) =>
        ToolGuard.Run(() =>
        {
            using var caller = LeaseSession.Use(session, owner);
            var lease = Of(slot);
            var release = lease.Release(owner, force);
            var after = lease.Snapshot();
            var what = slot == null ? "the shared stack" : $"slot '{slot}'";
            static string Who(LeaseInfo l) => $"'{l.Owner}'{(l.Session != null ? $" (session {l.Session})" : "")}";
            var note = release.Former == null
                ? $"Nothing released: the lease of {what} was not held (free, or it expired)."
                : $"Released the lease of {what} held by {Who(release.Former)}; " +
                  (after.Holder == null ? "it is free now."
                      : ReferenceEquals(after.Holder, release.Next) || release.Next != null && after.Holder.Owner == release.Next.Owner
                          ? $"the first waiting session, {Who(after.Holder)}, holds it now."
                          : $"{Who(after.Holder)} holds it now.");
            return new LeaseReleaseResult(release.Former != null, release.Former, after.Holder, after.Queue, note);
        });
}
