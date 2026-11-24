using System.Collections.Concurrent;

namespace Meshmakers.Octo.DevStack.Runtime;

/// <summary>A lane_remove that runs: who removes the lane and since when (lane_list shows it as <c>removing</c>).</summary>
public sealed record LaneRemoval(string Lane, string Owner, string? Session, DateTimeOffset Since)
{
    /// <summary>The lane stack's slot: a call that names only the slot is refused too, also once the lane's manifest is gone.</summary>
    public string? Slot { get; init; }

    /// <summary>
    ///     The lane folder and its repo paths (worktrees may lie outside the folder): a service of any stack that would start
    ///     from one of them is refused too, also when its source is a plain folder or a source the stack kept (AB#9673).
    /// </summary>
    public IReadOnlyList<string> Paths { get; init; } = [];
}

/// <summary>
///     The lanes being removed (AB#9673). lane_remove marks its lane first; while the mark is set every changing call on the
///     lane - a stack start, stop or restart, stack_setup, a build or test job, the lane_* calls that change it - is refused
///     with the holder and the way out, from every session (they all act as the lane, so its lease does not tell them apart).
///     The mark goes in a finally, whatever the removal did. In memory only: a daemon that ends drops it, so no lane stays
///     marked after a crash.
/// </summary>
public sealed class LaneRemovals
{
    private readonly ConcurrentDictionary<string, LaneRemoval> _marks = new(StringComparer.OrdinalIgnoreCase);

    /// <summary>Whether any lane is being removed (the start path skips its checks when none is).</summary>
    public bool Any => !_marks.IsEmpty;

    /// <summary>The removal of <paramref name="lane"/> that runs, or null.</summary>
    public LaneRemoval? Of(string lane) => _marks.GetValueOrDefault(lane.Trim());

    /// <summary>Marks the lane as being removed; refused when another removal of it runs. Dispose ends the mark.</summary>
    public IDisposable Begin(string lane, string owner, string? session, string? slot = null, IReadOnlyList<string>? paths = null)
    {
        var mark = new LaneRemoval(lane.Trim(), owner.Trim(), session, DateTimeOffset.Now)
        {
            Slot = slot, Paths = paths?.Where(p => !string.IsNullOrWhiteSpace(p)).ToList() ?? []
        };
        if (!_marks.TryAdd(mark.Lane, mark))
        {
            // Never without a mark: the other removal may have ended between TryAdd and Refuse, so refuse in any case.
            Refuse(lane);
            throw new InvalidOperationException($"Lane '{mark.Lane}' was being removed by another call a moment ago; look at lane_list and call again if it still exists.");
        }

        return new End(this, mark);
    }

    /// <summary>Throws when a lane whose stack runs in <paramref name="slot"/> is being removed (slot-only calls).</summary>
    public void RefuseSlot(string? slot)
    {
        if (OfSlot(slot) is { } mark)
        {
            Refuse(mark.Lane);
        }
    }

    /// <summary>The removal of the lane whose stack runs in <paramref name="slot"/>, or null.</summary>
    public LaneRemoval? OfSlot(string? slot) =>
        string.IsNullOrWhiteSpace(slot) ? null : _marks.Values.FirstOrDefault(m => string.Equals(m.Slot, slot.Trim(), StringComparison.Ordinal));

    /// <summary>
    ///     Throws when a service source - 'lane:&lt;name&gt;' or a folder - belongs to a lane that is being removed: the source
    ///     a call gives, and the one a stack kept (a restart without overrides, the restart after a build).
    /// </summary>
    public void RefuseSource(string? source)
    {
        if (string.IsNullOrWhiteSpace(source))
        {
            return;
        }

        if (Configuration.LaneSource.Is(source))
        {
            Refuse(source[Configuration.LaneSource.Prefix.Length..].Trim());
            return;
        }

        RefusePath(source);
    }

    /// <summary>Throws when <paramref name="path"/> is (or lies below) the folder or a repo path of a lane that is being removed.</summary>
    public void RefusePath(string? path)
    {
        if (LaneOfPath(path) is { } lane)
        {
            Refuse(lane);
        }
    }

    /// <summary>The lane being removed whose folder or repo path holds <paramref name="path"/> (relative paths are not matched), or null.</summary>
    public string? LaneOfPath(string? path)
    {
        if (string.IsNullOrWhiteSpace(path) || !Path.IsPathFullyQualified(path) || _marks.IsEmpty)
        {
            return null;
        }

        return _marks.Values.FirstOrDefault(m => m.Paths.Any(p => Common.PathScope.IsUnder(path, p)))?.Lane;
    }

    /// <summary>Throws when the lane is being removed: who removes it, since when, and what to do.</summary>
    public void Refuse(string? lane)
    {
        if (string.IsNullOrWhiteSpace(lane) || Of(lane) is not { } mark)
        {
            return;
        }

        throw new InvalidOperationException(
            $"Lane '{mark.Lane}' is being removed by '{mark.Owner}'{(mark.Session != null ? $" (session {mark.Session})" : "")} since {mark.Since:HH:mm:ss}; " +
            "nothing new starts on it. Wait until the removal ends (lane_list shows 'removing' until then): a removed lane is gone, a failed removal " +
            "leaves it usable again.");
    }

    private sealed class End(LaneRemovals owner, LaneRemoval mark) : IDisposable
    {
        public void Dispose() => owner._marks.TryRemove(new KeyValuePair<string, LaneRemoval>(mark.Lane, mark));
    }
}
