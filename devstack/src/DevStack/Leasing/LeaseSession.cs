namespace Meshmakers.Octo.DevStack.Leasing;

/// <summary>
///     The calling session of a changing tool call (its ListAgents name, e.g. 'meshmakers-07'), next to its owner. A tool sets
///     it for the call (<see cref="Use"/>); a lease granted or renewed during the call for one of the call's owners (the
///     owner itself, or the lane holding its lane stack's lease) records it (<see cref="LeaseInfo.Session"/>), so another
///     session can message the holder. Ambient rather than a parameter of every supervisor, slot and queue method: a lease
///     granted on another call's behalf (a queued build that starts later) names no other owner, so it never picks up a
///     session that is not its own.
/// </summary>
public static class LeaseSession
{
    private static readonly AsyncLocal<Caller?> Current = new();

    /// <summary>Sets the session for <paramref name="owners"/> until the result is disposed. Without a session nothing changes.</summary>
    public static IDisposable Use(string? session, params string?[] owners)
    {
        var previous = Current.Value;
        if (!string.IsNullOrWhiteSpace(session))
        {
            Current.Value = new Caller(session.Trim(), owners.Where(o => !string.IsNullOrWhiteSpace(o)).Select(o => o!.Trim()).ToList());
        }

        return new Restore(previous);
    }

    /// <summary>The session of the current call when <paramref name="owner"/> is one of its owners, else null.</summary>
    public static string? Of(string owner) =>
        Current.Value is { } caller && caller.Owners.Any(o => string.Equals(o, owner.Trim(), StringComparison.OrdinalIgnoreCase)) ? caller.Session : null;

    private sealed record Caller(string Session, IReadOnlyList<string> Owners);

    private sealed class Restore(Caller? previous) : IDisposable
    {
        public void Dispose() => Current.Value = previous;
    }
}
