namespace Meshmakers.Octo.DevStack.Leasing;

public sealed record LeaseInfo(string Owner, string? Purpose, DateTimeOffset AcquiredAt, DateTimeOffset ExpiresAt)
{
    /// <summary>
    ///     The idle timeout the holder asked for (lease_acquire ttlMinutes): the lease expires this long after its last
    ///     activity; every renewal keeps it. Null: the default.
    /// </summary>
    public int? TtlMinutes { get; init; }

    /// <summary>
    ///     The holder's last activity: the grant, the last renewal by a changing call, or the end of a pin (local time). Null in
    ///     a state file of an older daemon; <see cref="LastActivity"/> works it out from the expiry then.
    /// </summary>
    [System.Text.Json.Serialization.JsonIgnore(Condition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull)]
    public DateTimeOffset? LastActivityAt { get; init; }

    /// <summary>
    ///     Whole minutes since <see cref="LastActivityAt"/>, set on the copies lease_status shows (never persisted: the state
    ///     file is written from the holder itself, which has none).
    /// </summary>
    [System.Text.Json.Serialization.JsonIgnore(Condition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull)]
    public int? IdleMinutes { get; init; }

    /// <summary>
    ///     The last activity, also for a lease restored from an older state file: every renewal set the expiry to its time plus
    ///     the TTL, so the expiry minus the TTL is the last renewal (without a recorded TTL: the grant).
    /// </summary>
    public DateTimeOffset LastActivity() =>
        LastActivityAt ?? (TtlMinutes is { } minutes && ExpiresAt - TimeSpan.FromMinutes(minutes) is var renewed && renewed > AcquiredAt ? renewed : AcquiredAt);

    /// <summary>
    ///     The holder's session (its ListAgents name), to message it: given by the call that took the lease or by the last
    ///     changing call that renewed it with one (<see cref="LeaseSession"/>). Null: no call named one.
    /// </summary>
    [System.Text.Json.Serialization.JsonIgnore(Condition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull)]
    public string? Session { get; init; }
}

public sealed record LeaseWaiterInfo(string Owner, string? Purpose, DateTimeOffset Since)
{
    /// <summary>The waiting session (lease_acquire session), or null.</summary>
    [System.Text.Json.Serialization.JsonIgnore(Condition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull)]
    public string? Session { get; init; }
}

public sealed record LeaseSnapshot(LeaseInfo? Holder, IReadOnlyList<LeaseWaiterInfo> Queue);

/// <summary>What a release did: the holder it released (null: the lease was free) and the waiter it handed the lease to (null: none waited).</summary>
public sealed record LeaseRelease(LeaseInfo? Former, LeaseInfo? Next);

/// <summary>Thrown when another session holds the stack.</summary>
public sealed class LeaseHeldException(string message) : Exception(message);

/// <summary>
///     One session at a time owns the stack. Changing calls take the lease implicitly when it is free and nobody waits
///     ahead; every changing call of the holder renews it. Waiters are served first come, first served. The TTL is an idle
///     timeout: the lease expires that long after the holder's last activity (unless a build pins it).
/// </summary>
public sealed class LeaseManager
{
    /// <summary>
    ///     How long a holder may stay idle (no changing call) before the lease expires. Short on purpose: several sessions share
    ///     the stack, and a session that forgot lease_release must not block the others for hours.
    /// </summary>
    public static readonly TimeSpan DefaultTtl = TimeSpan.FromMinutes(30);

    private readonly Lock _lock = new();
    private readonly Dictionary<string, int> _pins = new(StringComparer.OrdinalIgnoreCase);
    private readonly LinkedList<Waiter> _queue = new();
    private readonly TimeProvider _time;
    private LeaseInfo? _holder;
    private bool _expiredPending;

    public LeaseManager(TimeProvider? time = null, LeaseInfo? restored = null, string? slot = null)
    {
        _time = time ?? TimeProvider.System;
        _holder = restored;
        Slot = slot ?? "default";
    }

    /// <summary>The stack slot this lease is for.</summary>
    public string Slot { get; }

    /// <summary>"The shared stack" for the default slot, "The stack of slot 'x'" (a lane's slot is named after the lane) for another one.</summary>
    private string What => Slot == "default" ? "The shared stack" : $"The stack of slot '{Slot}'";

    /// <summary>Raised (outside the lock) whenever the holder changes, for persistence.</summary>
    public event Action<LeaseInfo?>? Changed;

    /// <summary>The holder (with how long it has been idle) and the queue.</summary>
    public LeaseSnapshot Snapshot()
    {
        LeaseSnapshot snapshot;
        lock (_lock)
        {
            ExpireLocked();
            snapshot = new LeaseSnapshot(_holder == null ? null : WithIdle(_holder),
                _queue.Select(w => new LeaseWaiterInfo(w.Owner, w.Purpose, w.Since) { Session = w.Session }).ToList());
        }

        RaiseExpired();
        return snapshot;
    }

    /// <summary>
    ///     The holder right now, without raising <see cref="Changed"/> (for handlers of it: the lane claims write the current
    ///     holder, not the possibly outdated event argument).
    /// </summary>
    public LeaseInfo? Current()
    {
        lock (_lock)
        {
            ExpireLocked();
            return _holder;
        }
    }

    /// <summary>An expiry found by any call is announced once, outside the lock, so claims and the state file follow it.</summary>
    private void RaiseExpired()
    {
        bool raise;
        lock (_lock)
        {
            raise = _expiredPending;
            _expiredPending = false;
        }

        if (raise)
        {
            Changed?.Invoke(null);
        }
    }

    /// <summary>
    ///     Takes or renews the lease for a changing call, or throws when someone else holds it or waits ahead. The session is
    ///     <paramref name="session"/>, else the one the current call names for <paramref name="owner"/> (<see cref="LeaseSession"/>).
    /// </summary>
    public LeaseInfo Require(string owner, string? purpose = null, TimeSpan? ttl = null, string? session = null)
    {
        ValidateOwner(owner);
        LeaseInfo result;
        lock (_lock)
        {
            ExpireLocked();
            if (_holder != null && !Same(_holder.Owner, owner))
            {
                throw new LeaseHeldException(
                    $"{What} is held by '{_holder.Owner}'{(_holder.Session != null ? $" (session {_holder.Session})" : "")} " +
                    $"({_holder.Purpose ?? "no purpose given"}) since {_holder.AcquiredAt:HH:mm}, " +
                    $"last active {_holder.LastActivity():HH:mm}, expires {_holder.ExpiresAt:HH:mm} unless it is active again. " +
                    "Wait with lease_acquire(waitSeconds) or ask that session to call lease_release.");
            }

            if (_holder == null && _queue.First is { } first && !Same(first.Value.Owner, owner))
            {
                throw new LeaseHeldException($"{What} is free but '{first.Value.Owner}' waits for it first. Queue with lease_acquire.");
            }

            result = GrantLocked(owner, purpose ?? _holder?.Purpose, ttl ?? HeldTtlLocked(owner), session ?? LeaseSession.Of(owner));
        }

        RaiseExpired();
        Changed?.Invoke(result);
        return result;
    }

    /// <summary>Takes the lease, waiting up to <paramref name="wait"/> in the queue. Returns null on timeout.</summary>
    public async Task<LeaseInfo?> AcquireAsync(string owner, string? purpose, TimeSpan ttl, TimeSpan wait, CancellationToken cancellationToken,
        string? session = null)
    {
        session = string.IsNullOrWhiteSpace(session) ? LeaseSession.Of(owner) : session.Trim();
        ValidateOwner(owner);
        Waiter? waiter = null;
        LeaseInfo? granted = null;
        lock (_lock)
        {
            ExpireLocked();
            if (_holder != null && Same(_holder.Owner, owner) || _holder == null && (_queue.First == null || Same(_queue.First.Value.Owner, owner)))
            {
                granted = GrantLocked(owner, purpose, ttl, session);
                // Another call of the same owner may still wait on its queue entry: it returns this lease too.
                RemoveWaiterLocked(owner, granted);
            }
            else if (wait <= TimeSpan.Zero)
            {
                return null;
            }
            else
            {
                // Calls of the same owner share its one queue entry; each counts as a caller of it.
                waiter = _queue.FirstOrDefault(w => Same(w.Owner, owner)) ?? _queue.AddLast(new Waiter(owner, purpose, _time.GetLocalNow(), session, ttl)).Value;
                waiter.Callers++;
            }
        }

        RaiseExpired();
        if (granted != null || waiter == null)
        {
            Changed?.Invoke(granted);
            return granted;
        }

        using var timeout = new CancellationTokenSource(wait);
        using var linked = CancellationTokenSource.CreateLinkedTokenSource(timeout.Token, cancellationToken);
        try
        {
            while (true)
            {
                LeaseInfo? next = null;
                LeaseInfo? handed;
                lock (_lock)
                {
                    // A release hands the lease to the first waiter itself (and announced it already).
                    handed = waiter.Granted;
                    if (handed == null)
                    {
                        ExpireLocked();
                        if (_holder == null && _queue.First?.Value == waiter)
                        {
                            _queue.RemoveFirst();
                            next = GrantLocked(owner, purpose, ttl, session);
                            waiter.Granted = next; // the other calls sharing the entry return it as well
                            waiter.Notify();
                        }
                    }

                    if (handed != null || next != null)
                    {
                        // Returned to a caller: no other call on this entry may take it back when it is canceled.
                        waiter.Claimed = true;
                        waiter.Callers--;
                    }
                }

                RaiseExpired();
                if (handed != null)
                {
                    return handed;
                }

                if (next != null)
                {
                    Changed?.Invoke(next);
                    return next;
                }

                await Task.WhenAny(waiter.Signal.Task, Task.Delay(TimeSpan.FromSeconds(1), linked.Token));
                waiter.ResetSignal();
                linked.Token.ThrowIfCancellationRequested();
            }
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            lock (_lock)
            {
                waiter.Callers--;
                if (waiter.Granted != null)
                {
                    // Handed over in the moment the wait ran out: the caller holds it.
                    waiter.Claimed = true;
                    return waiter.Granted;
                }

                if (waiter.Callers <= 0)
                {
                    _queue.Remove(waiter);
                }

                return null;
            }
        }
        catch (OperationCanceledException)
        {
            LeaseInfo? next = null;
            var gaveBack = false;
            lock (_lock)
            {
                // Another call of the same owner still waits on the entry: it keeps its place and gets (or got) the lease.
                waiter.Callers--;
                if (waiter.Callers <= 0)
                {
                    _queue.Remove(waiter);
                }

                // Only a handover no call returned, while the holder is still exactly that grant (not released and taken anew).
                if (waiter.Callers <= 0 && waiter.Granted != null && !waiter.Claimed && ReferenceEquals(_holder, waiter.Granted))
                {
                    // The caller is gone: a lease handed to it goes on to the next waiter.
                    _holder = null;
                    next = HandOverLocked();
                    gaveBack = true;
                }
            }

            if (gaveBack)
            {
                Changed?.Invoke(next);
            }

            throw;
        }
    }

    /// <summary>
    ///     Releases the lease and hands it to the first waiter at once (its lease_acquire returns it). Without force only the
    ///     holder may release. Former is null when the lease was free (never taken, or expired).
    /// </summary>
    public LeaseRelease Release(string owner, bool force)
    {
        LeaseInfo? former = null;
        LeaseInfo? next = null;
        lock (_lock)
        {
            ExpireLocked();
            if (_holder != null)
            {
                if (!force && !Same(_holder.Owner, owner))
                {
                    throw new LeaseHeldException($"The lease belongs to '{_holder.Owner}', not to '{owner}'.");
                }

                former = _holder;
                _holder = null;
                next = HandOverLocked();
            }
        }

        RaiseExpired();
        if (former != null)
        {
            Changed?.Invoke(next);
        }

        return new LeaseRelease(former, next);
    }

    /// <summary>Grants the free lease to the first waiter (removed from the queue) and wakes it; null when nobody waits.</summary>
    private LeaseInfo? HandOverLocked()
    {
        if (_queue.First is not { } first)
        {
            return null;
        }

        _queue.RemoveFirst();
        var waiter = first.Value;
        waiter.Granted = GrantLocked(waiter.Owner, waiter.Purpose, waiter.Ttl, waiter.Session);
        waiter.Notify();
        return waiter.Granted;
    }

    /// <summary>
    ///     Keeps the owner's lease from expiring while something long-running holds it (a build of up to 3 h). Releasing
    ///     the lease stays possible. Disposing the pin renews the lease once (like a changing call).
    /// </summary>
    public IDisposable Pin(string owner)
    {
        ValidateOwner(owner);
        var key = owner.Trim();
        lock (_lock)
        {
            _pins[key] = _pins.GetValueOrDefault(key) + 1;
        }

        return new PinHandle(this, key);
    }

    public bool IsPinned(string owner)
    {
        lock (_lock)
        {
            return _pins.ContainsKey(owner.Trim());
        }
    }

    private void Unpin(string owner)
    {
        LeaseInfo? renewed = null;
        lock (_lock)
        {
            if (_pins.TryGetValue(owner, out var count))
            {
                if (count <= 1)
                {
                    _pins.Remove(owner);
                }
                else
                {
                    _pins[owner] = count - 1;
                }
            }

            if (_holder != null && Same(_holder.Owner, owner))
            {
                renewed = GrantLocked(owner, _holder.Purpose, HeldTtlLocked(owner), null);
            }
        }

        if (renewed != null)
        {
            Changed?.Invoke(renewed);
        }
    }

    private sealed class PinHandle(LeaseManager manager, string owner) : IDisposable
    {
        private int _disposed;

        public void Dispose()
        {
            if (Interlocked.Exchange(ref _disposed, 1) == 0)
            {
                manager.Unpin(owner);
            }
        }
    }

    /// <summary>The TTL a renewal of <paramref name="owner"/> keeps: the one it asked for when it took the lease, else the default.</summary>
    private TimeSpan HeldTtlLocked(string owner) =>
        _holder != null && Same(_holder.Owner, owner) && _holder.TtlMinutes is { } minutes ? TimeSpan.FromMinutes(minutes) : DefaultTtl;

    /// <summary>
    ///     Takes or renews the lease: it expires <paramref name="ttl"/> after now, the holder's last activity. A renewal without
    ///     a session keeps the holder's; a new holder has the given one (or none).
    /// </summary>
    private LeaseInfo GrantLocked(string owner, string? purpose, TimeSpan ttl, string? session)
    {
        // Local time: these values are shown to the developer.
        var now = _time.GetLocalNow();
        var minutes = (int)Math.Round(ttl.TotalMinutes);
        _holder = _holder != null && Same(_holder.Owner, owner)
            ? _holder with { Purpose = purpose ?? _holder.Purpose, ExpiresAt = now + ttl, TtlMinutes = minutes, LastActivityAt = now, Session = session ?? _holder.Session }
            : new LeaseInfo(owner.Trim(), purpose, now, now + ttl) { TtlMinutes = minutes, LastActivityAt = now, Session = session };
        return _holder;
    }

    /// <summary>A copy of <paramref name="holder"/> that says when it was last active and how long ago (whole minutes, never below 0).</summary>
    private LeaseInfo WithIdle(LeaseInfo holder)
    {
        var last = holder.LastActivity();
        var idle = _time.GetUtcNow() - last;
        return holder with { LastActivityAt = last, IdleMinutes = idle <= TimeSpan.Zero ? 0 : (int)Math.Floor(idle.TotalMinutes) };
    }

    private void ExpireLocked()
    {
        if (_holder != null && _holder.ExpiresAt <= _time.GetUtcNow() && !_pins.ContainsKey(_holder.Owner))
        {
            _expiredPending = true;
            _holder = null;
            _queue.First?.Value.Notify();
        }
    }

    /// <summary>Removes the owner's queue entry; a call still waiting on it returns <paramref name="granted"/>.</summary>
    private void RemoveWaiterLocked(string owner, LeaseInfo granted)
    {
        var existing = _queue.FirstOrDefault(w => Same(w.Owner, owner));
        if (existing != null)
        {
            _queue.Remove(existing);
            existing.Granted = granted;
            existing.Claimed = true; // the immediate grant went to a caller already
            existing.Notify();
        }
    }

    private static bool Same(string a, string b) => string.Equals(a.Trim(), b.Trim(), StringComparison.OrdinalIgnoreCase);

    private static void ValidateOwner(string owner)
    {
        if (string.IsNullOrWhiteSpace(owner))
        {
            throw new ArgumentException("owner is required: a stable name of your session, e.g. the branch '<user>/AB#8625_explicit-null-enum-record'.");
        }
    }

    private sealed class Waiter(string owner, string? purpose, DateTimeOffset since, string? session, TimeSpan ttl)
    {
        private TaskCompletionSource _signal = new(TaskCreationOptions.RunContinuationsAsynchronously);

        public string Owner { get; } = owner;
        public string? Purpose { get; } = purpose;
        public string? Session { get; } = session;
        public DateTimeOffset Since { get; } = since;
        public TimeSpan Ttl { get; } = ttl;

        /// <summary>The lease a release handed to this waiter (under the manager's lock).</summary>
        public LeaseInfo? Granted { get; set; }

        /// <summary>A call returned <see cref="Granted"/> to its caller (under the manager's lock): a canceled call never gives it back then.</summary>
        public bool Claimed { get; set; }

        /// <summary>The AcquireAsync calls still waiting on this entry (under the manager's lock).</summary>
        public int Callers { get; set; }
        public TaskCompletionSource Signal => _signal;

        public void Notify() => _signal.TrySetResult();

        public void ResetSignal()
        {
            if (_signal.Task.IsCompleted)
            {
                _signal = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            }
        }
    }
}
