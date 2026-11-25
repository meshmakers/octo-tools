using System.Collections.Concurrent;

namespace Meshmakers.Octo.DevStack.Runtime;

/// <summary>A lane_create or lane_add_repo that runs: which call, who started it and since when.</summary>
public sealed record LaneChange(string Lane, string Call, string Owner, DateTimeOffset Since);

/// <summary>
///     The lane changes that run (AB#9808). lane_create and lane_add_repo run to their end when the caller's MCP call times
///     out, so a caller that asks again, or queues a build or test run of the lane, could change or build a lane that is still
///     being changed: one change per lane at a time, and no new job of a lane while it changes.
/// </summary>
public sealed class LaneChanges
{
    private readonly ConcurrentDictionary<string, LaneChange> _marks = new(StringComparer.OrdinalIgnoreCase);

    /// <summary>The change of <paramref name="lane"/> that runs, or null.</summary>
    public LaneChange? Of(string? lane) => string.IsNullOrWhiteSpace(lane) ? null : _marks.GetValueOrDefault(lane.Trim());

    /// <summary>Marks the lane as being changed by <paramref name="call"/>; refused while another change of it runs. Dispose ends the mark.</summary>
    public IDisposable Begin(string lane, string call, string owner)
    {
        var mark = new LaneChange(lane.Trim(), call, owner.Trim(), DateTimeOffset.Now);
        if (!_marks.TryAdd(mark.Lane, mark))
        {
            Refuse(mark.Lane);
            throw new InvalidOperationException($"Lane '{mark.Lane}' was being changed by another call a moment ago; look at lane_list and call again.");
        }

        return new End(this, mark);
    }

    /// <summary>Throws while a change of the lane runs: which call, who started it, since when, and what to do.</summary>
    public void Refuse(string? lane)
    {
        if (Of(lane) is not { } mark)
        {
            return;
        }

        throw new InvalidOperationException(
            $"Lane '{mark.Lane}' is being changed: {mark.Call} of '{mark.Owner}' runs since {mark.Since:HH:mm:ss} (it goes on when its caller's call " +
            "timed out). Nothing was started. Call again when it ended - lane_list shows its result (the lane's repos and slot).");
    }

    private sealed class End(LaneChanges owner, LaneChange mark) : IDisposable
    {
        public void Dispose() => owner._marks.TryRemove(new KeyValuePair<string, LaneChange>(mark.Lane, mark));
    }
}
