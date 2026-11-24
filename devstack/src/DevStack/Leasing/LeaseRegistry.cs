namespace Meshmakers.Octo.DevStack.Leasing;

/// <summary>
///     One <see cref="LeaseManager"/> per stack slot. An owner may hold the leases of several slots; a slot's lease is
///     created on first use. <see cref="Changed"/> forwards every manager's changes with the slot name (state file, claims).
/// </summary>
public sealed class LeaseRegistry
{
    private readonly Lock _lock = new();
    private readonly Dictionary<string, LeaseManager> _leases = new(StringComparer.Ordinal);
    private readonly Dictionary<string, LeaseInfo> _restored;
    private readonly TimeProvider? _time;

    /// <param name="defaultLease">The lease of the default slot (the one the single-stack tools always used).</param>
    /// <param name="restored">Leases of other slots from the state file.</param>
    public LeaseRegistry(LeaseManager defaultLease, IReadOnlyDictionary<string, LeaseInfo>? restored = null, TimeProvider? time = null)
    {
        _time = time;
        _restored = restored?.Where(r => r.Key != defaultLease.Slot).ToDictionary(r => r.Key, r => r.Value, StringComparer.Ordinal)
                    ?? new Dictionary<string, LeaseInfo>(StringComparer.Ordinal);
        Default = defaultLease;
        Add(defaultLease);
        foreach (var slot in _restored.Keys.ToList())
        {
            Get(slot);
        }
    }

    public LeaseManager Default { get; }

    /// <summary>Raised whenever the holder of a slot's lease changes: (slot, lease or null).</summary>
    public event Action<string, LeaseInfo?>? Changed;

    /// <summary>The lease of a slot, created when it does not exist yet.</summary>
    public LeaseManager Get(string slot)
    {
        lock (_lock)
        {
            if (_leases.TryGetValue(slot, out var existing))
            {
                return existing;
            }

            var manager = new LeaseManager(_time, _restored.GetValueOrDefault(slot), slot);
            Add(manager);
            return manager;
        }
    }

    /// <summary>The lease of a slot, or null when nobody ever used it.</summary>
    public LeaseManager? Find(string slot)
    {
        lock (_lock)
        {
            return _leases.GetValueOrDefault(slot);
        }
    }

    /// <summary>Every slot's lease (default first).</summary>
    public IReadOnlyList<LeaseManager> All
    {
        get
        {
            lock (_lock)
            {
                return _leases.Values.OrderBy(l => l == Default ? 0 : 1).ThenBy(l => l.Slot, StringComparer.Ordinal).ToList();
            }
        }
    }

    /// <summary>The slots whose lease <paramref name="owner"/> holds right now.</summary>
    public List<string> HeldBy(string owner) =>
        All.Where(l => l.Current() is { } holder && string.Equals(holder.Owner.Trim(), owner.Trim(), StringComparison.OrdinalIgnoreCase))
            .Select(l => l.Slot).ToList();

    /// <summary>Looks at every lease (expiry raises <see cref="Changed"/>).</summary>
    public void Tick()
    {
        foreach (var lease in All)
        {
            lease.Snapshot();
        }
    }

    private void Add(LeaseManager manager)
    {
        _leases[manager.Slot] = manager;
        manager.Changed += info => Changed?.Invoke(manager.Slot, info);
    }
}
