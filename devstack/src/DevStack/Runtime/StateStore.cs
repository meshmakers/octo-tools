using System.Text.Json;
using System.Text.Json.Serialization;
using Meshmakers.Octo.DevStack.Common;
using Meshmakers.Octo.DevStack.Configuration;
using Meshmakers.Octo.DevStack.Leasing;

namespace Meshmakers.Octo.DevStack.Runtime;

/// <summary>What survives a daemon restart: the processes it started and the leases, per slot. No environment values.</summary>
public sealed class PersistedState
{
    /// <summary>The default slot's stack. Legacy field, still written for one release so an older daemon can adopt it.</summary>
    public PersistedStack? Stack { get; set; }

    /// <summary>The default slot's lease. Legacy field, still written for one release.</summary>
    public LeaseInfo? Lease { get; set; }

    /// <summary>Stacks keyed by slot ("default" included).</summary>
    public Dictionary<string, PersistedStack>? Stacks { get; set; }

    /// <summary>Leases keyed by slot ("default" included).</summary>
    public Dictionary<string, LeaseInfo>? Leases { get; set; }

    /// <summary>Indices of slots created on first use (not in devstack.yaml); an index is never reused while it is listed here.</summary>
    public Dictionary<string, int>? SlotIndices { get; set; }

    /// <summary>
    ///     Indices of removed slots whose data may still exist (keyed by index): never handed out again until admin_slot_forget
    ///     un-retires one after the developer dropped its data.
    /// </summary>
    public Dictionary<int, RetiredSlot>? RetiredSlots { get; set; }

    /// <summary>The first running build. Legacy field, still written for one release; <see cref="Builds"/> holds all of them.</summary>
    public PersistedBuild? Build { get; set; }

    /// <summary>
    ///     Every build whose process runs right now. The job files (<c>builds/&lt;id&gt;.job.json</c>) are what a restart restores
    ///     from; an entry here without a job file is a build of a daemon version before them and is taken over by its pid.
    /// </summary>
    public List<PersistedBuild>? Builds { get; set; }

    /// <summary>The running builds, also from a state file written before <see cref="Builds"/> existed.</summary>
    public List<PersistedBuild> RunningBuilds() => Builds ?? (Build == null ? [] : [Build]);
}

/// <summary>A removed slot whose index is kept back, with the data it left (and the commands to drop it).</summary>
public sealed class RetiredSlot
{
    public string Name { get; set; } = "";
    public string Prefix { get; set; } = "";
    public int PortOffset { get; set; }
    public DateTimeOffset RetiredAt { get; set; }

    /// <summary>The tenant databases the slot's system database registered when it was removed (null: not known).</summary>
    public List<string>? TenantDatabases { get; set; }
    /// <summary>Generated when read (StackSupervisor.RetiredSlots); not written any more, an old state file's copy is ignored.</summary>
    [System.Text.Json.Serialization.JsonIgnore(Condition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingDefault)]
    public List<SlotLeftover>? Leftovers { get; set; }
}

public sealed class PersistedBuild
{
    public string Id { get; set; } = "";
    public string Owner { get; set; } = "";
    public string Kind { get; set; } = "";
    public string Target { get; set; } = "";
    public int Pid { get; set; }
    public DateTimeOffset StartedAt { get; set; }
    public string LogFile { get; set; } = "";
}

public sealed class PersistedStack
{
    public string Checkout { get; set; } = "";
    public string Configuration { get; set; } = "";
    public DateTimeOffset StartedAt { get; set; }
    public string? StartedBy { get; set; }

    /// <summary>The profile the stack was started from and its hash at that time (instances are re-read from it).</summary>
    public string? Profile { get; set; }

    public string? ProfileHash { get; set; }

    public List<PersistedService> Services { get; set; } = new();

    /// <summary>
    ///     Services a build stopped and starts again when it ends (paths only, like <see cref="Services"/>; the build's job
    ///     file has their overrides). A daemon restart during the build shows them as stopped-for-build again and lets
    ///     service_restart start them, instead of forgetting them until the build ends.
    /// </summary>
    public List<PersistedService> StoppedForBuild { get; set; } = new();
}

public static class PersistedStateExtensions
{
    /// <summary>
    ///     The stacks by slot. The legacy field is authoritative for the default slot: both are written together, and when
    ///     they differ a single-stack daemon (an older version) wrote the file last.
    /// </summary>
    public static Dictionary<string, PersistedStack> StacksBySlot(this PersistedState state) => BySlot(state.Stacks, state.Stack);

    /// <summary>The leases by slot; the legacy field is authoritative for the default slot (see <see cref="StacksBySlot"/>).</summary>
    public static Dictionary<string, LeaseInfo> LeasesBySlot(this PersistedState state) => BySlot(state.Leases, state.Lease);

    private static Dictionary<string, T> BySlot<T>(Dictionary<string, T>? map, T? legacy) where T : class
    {
        var result = new Dictionary<string, T>(map ?? [], StringComparer.Ordinal);
        result.Remove(SlotInfo.DefaultName);
        if (legacy != null)
        {
            result[SlotInfo.DefaultName] = legacy;
        }

        return result;
    }
}

public sealed class PersistedService
{
    public string Name { get; set; } = "";
    public int Pid { get; set; }
    public string Command { get; set; } = "";
    public List<string> Args { get; set; } = new();
    public string WorkingDirectory { get; set; } = "";
    public string RepoPath { get; set; } = "";
    public string? Source { get; set; }
    public string LogFile { get; set; } = "";
    public List<int> Ports { get; set; } = new();
    public string? HealthUrl { get; set; }
    public DateTimeOffset StartedAt { get; set; }

    /// <summary>The OS start time of <see cref="Pid"/> at launch; adoption requires it to match (pid reuse). Null in older state files.</summary>
    public DateTimeOffset? ProcessStartTime { get; set; }

    /// <summary>
    ///     Who started or overrode the service (<see cref="ServiceOrigin"/>) and with which call. Null in older state files:
    ///     adoption falls back to the stack's <see cref="PersistedStack.StartedBy"/>.
    /// </summary>
    public string? StartedBy { get; set; }

    public string? StartedVia { get; set; }

    /// <summary>The session of <see cref="StartedBy"/> (<see cref="ServiceOrigin.Session"/>), when the caller named one.</summary>
    public string? StartedBySession { get; set; }
}

public sealed class StateStore(DevStackPaths paths)
{
    public DevStackPaths Paths { get; } = paths;

    private static readonly JsonSerializerOptions Options = new()
    {
        WriteIndented = true,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull
    };

    private readonly Lock _lock = new();
    private PersistedState _state = new();

    public PersistedState Load()
    {
        lock (_lock)
        {
            if (File.Exists(Paths.StateFile))
            {
                try
                {
                    _state = JsonSerializer.Deserialize<PersistedState>(Common.SharedFile.ReadAllText(Paths.StateFile), Options) ?? new PersistedState();
                }
                catch (JsonException)
                {
                    File.Move(Paths.StateFile, Paths.StateFile + ".corrupt", overwrite: true);
                    _state = new PersistedState();
                }
            }

            return _state;
        }
    }

    public void SaveStack(PersistedStack? stack) => SaveStack(SlotInfo.DefaultName, stack);

    /// <summary>Writes the stack of a slot (null removes it); the default slot also goes into the legacy field.</summary>
    public void SaveStack(string slot, PersistedStack? stack)
    {
        lock (_lock)
        {
            _state.Stacks = Set(_state.StacksBySlot(), slot, stack);
            if (slot == SlotInfo.DefaultName)
            {
                _state.Stack = stack;
            }

            WriteLocked();
        }
    }

    public void SaveLease(LeaseInfo? lease) => SaveLease(SlotInfo.DefaultName, lease);

    /// <summary>Writes the lease of a slot (null removes it); the default slot also goes into the legacy field.</summary>
    public void SaveLease(string slot, LeaseInfo? lease)
    {
        lock (_lock)
        {
            _state.Leases = Set(_state.LeasesBySlot(), slot, lease);
            if (slot == SlotInfo.DefaultName)
            {
                _state.Lease = lease;
            }

            WriteLocked();
        }
    }

    /// <summary>Records the index of a slot created on first use.</summary>
    public void SaveSlotIndex(string slot, int index)
    {
        lock (_lock)
        {
            _state.SlotIndices ??= new Dictionary<string, int>(StringComparer.Ordinal);
            _state.SlotIndices[slot] = index;
            WriteLocked();
        }
    }

    /// <summary>Retires a created slot (lane_remove): its name is free, its index is kept back with the data it left.</summary>
    public void RetireSlot(string slot, int index, RetiredSlot retired)
    {
        lock (_lock)
        {
            _state.SlotIndices?.Remove(slot);
            _state.RetiredSlots ??= new Dictionary<int, RetiredSlot>();
            _state.RetiredSlots[index] = retired;
            WriteLocked();
        }
    }

    /// <summary>
    ///     The tenant databases of a retired index that remain after a partial data drop (the system database that registered
    ///     them may be gone). Unlike <see cref="RetireSlot"/> it leaves the slot names alone: a new slot of the same name keeps its index.
    /// </summary>
    public void UpdateRetiredSlot(int index, List<string>? tenantDatabases)
    {
        lock (_lock)
        {
            if (_state.RetiredSlots?.GetValueOrDefault(index) is not { } retired)
            {
                return;
            }

            retired.TenantDatabases = tenantDatabases is { Count: > 0 } ? tenantDatabases : null;
            WriteLocked();
        }
    }

    /// <summary>Un-retires an index (admin_slot_forget, or once its data is dropped): it may be handed out again. False when it was not retired.</summary>
    public bool ForgetRetiredSlot(int index)
    {
        lock (_lock)
        {
            if (_state.RetiredSlots?.Remove(index) != true)
            {
                return false;
            }

            if (_state.RetiredSlots.Count == 0)
            {
                _state.RetiredSlots = null;
            }

            WriteLocked();
            return true;
        }
    }

    /// <summary>The retired slot indices with what they left.</summary>
    public Dictionary<int, RetiredSlot> RetiredSlots()
    {
        lock (_lock)
        {
            return new Dictionary<int, RetiredSlot>(_state.RetiredSlots ?? []);
        }
    }

    /// <summary>The indices of slots created on first use.</summary>
    public Dictionary<string, int> SlotIndices()
    {
        lock (_lock)
        {
            return new Dictionary<string, int>(_state.SlotIndices ?? [], StringComparer.Ordinal);
        }
    }

    private static Dictionary<string, T>? Set<T>(Dictionary<string, T> map, string key, T? value) where T : class
    {
        if (value == null)
        {
            map.Remove(key);
        }
        else
        {
            map[key] = value;
        }

        return map.Count == 0 ? null : map;
    }

    public void SaveBuild(PersistedBuild? build) => SaveBuilds(build == null ? [] : [build]);

    /// <summary>Records every running build (an empty list: none).</summary>
    public void SaveBuilds(IReadOnlyList<PersistedBuild> builds)
    {
        lock (_lock)
        {
            _state.Builds = builds.Count == 0 ? null : builds.ToList();
            _state.Build = builds.FirstOrDefault();
            WriteLocked();
        }
    }

    private void WriteLocked()
    {
        var temp = Paths.StateFile + ".tmp";
        File.WriteAllText(temp, JsonSerializer.Serialize(_state, Options));
        Common.SharedFile.Replace(temp, Paths.StateFile);
    }
}
