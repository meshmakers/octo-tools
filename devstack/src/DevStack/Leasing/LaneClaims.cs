using System.Globalization;
using System.Text;

namespace Meshmakers.Octo.DevStack.Leasing;

/// <summary>
///     A claim file of the local stack resource (of one slot) in a lane. Session: the holder's session (ListAgents name) to
///     message; Owner: the lease holder the claim belongs to (a claim without an Owner line names it as Session).
/// </summary>
public sealed record LaneClaim(
    string Lane,
    string Resource,
    string File,
    string? Session,
    string? Purpose,
    DateTimeOffset? Since,
    DateTimeOffset? Expires,
    bool ManagedByDevStack)
{
    public string? Owner { get; init; }
}

/// <summary>Thrown when another session claims the local stack of a lane.</summary>
public sealed class LaneClaimedException(string message) : InvalidOperationException(message);

/// <summary>
///     The exclusive-resource claim of the local OctoMesh stack, in the claim folder the agent operating rules define
///     (<c>&lt;lane&gt;/.octo/claims/</c>, one Markdown file per claimed thing, "- Key: value" lines naming session, purpose
///     and since). The rules list the local stack as an exclusive resource but do not fix a file name or an expiry field,
///     so this uses <c>local-stack.md</c> with the same list format plus <c>Expires</c> and <c>Managed by</c>.
///     Starting a stack in a lane writes the claim for the lease holder; every lease change rewrites it (owner, expiry);
///     releasing the lease removes it. A claim of another session that has not expired blocks a start in that lane.
///     Every stack slot is its own resource with its own file: <c>local-stack.md</c> for the default slot,
///     <c>local-stack-&lt;slot&gt;.md</c> for the others (<see cref="ResourceOf"/>). A claim only ever replaces the claim of
///     the same resource in another lane (the slot's stack moved); claims of other slots are left alone.
/// </summary>
public sealed class LaneClaims(TimeProvider? time = null)
{
    public const string Resource = "local-stack";
    private const string ManagedBy = "octo-devstack";
    private const string TimeFormat = "yyyy-MM-dd'T'HH:mm:sszzz";

    private readonly Lock _lock = new();
    private readonly HashSet<(string Lane, string Resource)> _claims = new();
    private readonly TimeProvider _time = time ?? TimeProvider.System;

    /// <summary>The claim resource of a stack slot: local-stack for the default slot, local-stack-&lt;slot&gt; else.</summary>
    public static string ResourceOf(string slot) => slot == "default" ? Resource : $"{Resource}-{slot}";

    /// <summary>Lanes whose claim this daemon wrote and keeps in step with the lease.</summary>
    public IReadOnlyCollection<string> Lanes
    {
        get
        {
            lock (_lock)
            {
                return _claims.Select(c => c.Lane).Distinct().ToList();
            }
        }
    }

    /// <summary>The (lane, resource) pairs this daemon keeps in step with the leases.</summary>
    public IReadOnlyCollection<(string Lane, string Resource)> Tracked
    {
        get
        {
            lock (_lock)
            {
                return _claims.ToList();
            }
        }
    }

    public static string PathOf(string lane, string resource = Resource) => Path.Combine(lane, ".octo", "claims", resource + ".md");

    public LaneClaim? Read(string lane, string resource = Resource)
    {
        var file = PathOf(lane, resource);
        if (!File.Exists(file))
        {
            return null;
        }

        var values = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach (var raw in Common.SharedFile.ReadAllLines(file))
        {
            var line = raw.Trim();
            if (!line.StartsWith("- ", StringComparison.Ordinal))
            {
                continue;
            }

            var colon = line.IndexOf(':');
            if (colon > 2)
            {
                values.TryAdd(line[2..colon].Trim(), line[(colon + 1)..].Trim());
            }
        }

        return new LaneClaim(lane, resource, file, values.GetValueOrDefault("Session"), values.GetValueOrDefault("Purpose"),
            ParseTime(values.GetValueOrDefault("Since")), ParseTime(values.GetValueOrDefault("Expires")),
            values.GetValueOrDefault("Managed by")?.StartsWith(ManagedBy, StringComparison.OrdinalIgnoreCase) == true)
        {
            Owner = values.GetValueOrDefault("Owner") ?? values.GetValueOrDefault("Session")
        };
    }

    /// <summary>Throws when the lane's stack (of the slot of <paramref name="resource"/>) is claimed by another session and the claim has not expired.</summary>
    public void EnsureCanClaim(string lane, string owner, string resource = Resource)
    {
        var claim = Read(lane, resource);
        if (claim == null || Same(claim.Owner, owner) || claim.Expires is { } expires && expires <= _time.GetUtcNow())
        {
            return;
        }

        var until = claim.Expires is { } e ? $" until {e.ToLocalTime():HH:mm}" : " without expiry";
        var what = resource == Resource ? "The local stack" : $"The local stack slot '{resource[(Resource.Length + 1)..]}'";
        var holder = claim.Owner == null ? "an unnamed session"
            : $"'{claim.Owner}'" + (claim.Session != null && !Same(claim.Session, claim.Owner) ? $" (session '{claim.Session}')" : "");
        throw new LaneClaimedException(
            $"{what} of {lane} is claimed by {holder}" +
            $"{(claim.Purpose != null ? $" ({claim.Purpose})" : "")}{until}: {claim.File}. " +
            "Ask that session to release it (lease_release or removing its claim), or wait until the claim expires.");
    }

    /// <summary>Throws when any slot's stack of the lane is claimed by another session (a build that changes the whole lane).</summary>
    public void EnsureCanClaimAll(string lane, string owner)
    {
        var folder = Path.GetDirectoryName(PathOf(lane))!;
        if (!Directory.Exists(folder))
        {
            return;
        }

        foreach (var file in Directory.GetFiles(folder, Resource + "*.md").Order(StringComparer.Ordinal))
        {
            EnsureCanClaim(lane, owner, Path.GetFileNameWithoutExtension(file));
        }
    }

    /// <summary>
    ///     Writes the claim of <paramref name="lane"/> for the lease holder. The same resource's claim in another lane (the
    ///     slot's stack moved) is removed; claims of other resources are not touched.
    /// </summary>
    public void Claim(string lane, LeaseInfo lease, string resource = Resource)
    {
        lock (_lock)
        {
            foreach (var other in _claims.Where(c => c.Resource == resource && c.Lane != lane).ToList())
            {
                RemoveLocked(other);
            }

            _claims.Add((lane, resource));
            WriteLocked(lane, resource, lease);
        }
    }

    /// <summary>Keeps a claim of an earlier daemon run in step (after adoption), if it is ours.</summary>
    public void Track(string lane, string resource = Resource)
    {
        if (Read(lane, resource)?.ManagedByDevStack == true)
        {
            lock (_lock)
            {
                _claims.Add((lane, resource));
            }
        }
    }

    /// <summary>
    ///     The default slot's lease holder right now (<see cref="LeaseManager.Current"/>). Claims always follow it rather than
    ///     the event argument, so two lease changes whose events arrive out of order cannot leave the older holder on disk.
    /// </summary>
    public Func<LeaseInfo?>? CurrentLease { get; set; }

    /// <summary>The current holder of the lease a resource follows (all slots); wins over <see cref="CurrentLease"/>.</summary>
    public Func<string, LeaseInfo?>? CurrentLeaseOf { get; set; }

    public ILogger? Logger { get; set; }

    /// <summary>The default slot's lease changed (see <see cref="OnLeaseChanged(string, LeaseInfo?)"/>).</summary>
    public void OnLeaseChanged(LeaseInfo? lease) => OnLeaseChanged(Resource, lease);

    /// <summary>A lease changed: rewrite the resource's claims for the current holder or expiry; remove them when there is none. Never throws.</summary>
    public void OnLeaseChanged(string resource, LeaseInfo? lease)
    {
        lock (_lock)
        {
            var current = CurrentLeaseOf != null ? CurrentLeaseOf(resource)
                : resource == Resource && CurrentLease != null ? CurrentLease()
                : lease;
            foreach (var claim in _claims.Where(c => c.Resource == resource).ToList())
            {
                try
                {
                    if (current == null)
                    {
                        RemoveLocked(claim);
                    }
                    else
                    {
                        WriteLocked(claim.Lane, claim.Resource, current);
                    }
                }
                catch (Exception e) when (e is IOException or UnauthorizedAccessException)
                {
                    // A lane folder that went away or became unwritable: the lease change itself must not fail.
                    Logger?.LogWarning("Could not update the lane claim of {Lane}: {Message}", claim.Lane, e.Message);
                    if (e is DirectoryNotFoundException)
                    {
                        _claims.Remove(claim);
                    }
                }
            }
        }
    }

    private void WriteLocked(string lane, string resource, LeaseInfo lease)
    {
        var file = PathOf(lane, resource);
        var existing = Read(lane, resource);
        var since = existing != null && Same(existing.Owner, lease.Owner) && existing.Since is { } s ? s : lease.AcquiredAt;
        var text = new StringBuilder()
            .AppendLine("# Claim: local OctoMesh stack (exclusive resource)")
            .AppendLine()
            .AppendLine($"- Session: {lease.Session ?? lease.Owner}")
            .AppendLine($"- Owner: {lease.Owner}")
            .AppendLine($"- Purpose: {lease.Purpose ?? "not given"}")
            .AppendLine(resource == Resource
                ? $"- Resource: {Resource} (the services of this lane on the fixed ports, started by octo-devstack)"
                : $"- Resource: {resource} (the services of stack slot '{resource[(Resource.Length + 1)..]}' of this lane on shifted ports, started by octo-devstack)")
            .AppendLine($"- Since: {since.ToLocalTime().ToString(TimeFormat, CultureInfo.InvariantCulture)}")
            .AppendLine($"- Expires: {lease.ExpiresAt.ToLocalTime().ToString(TimeFormat, CultureInfo.InvariantCulture)}")
            .AppendLine($"- Managed by: {ManagedBy} lease; removed when the lease is released")
            .AppendLine()
            .AppendLine("Release it with lease_release on octo-devstack instead of deleting this file.")
            .ToString();
        Directory.CreateDirectory(Path.GetDirectoryName(file)!);
        var temp = file + ".tmp";
        File.WriteAllText(temp, text);
        Common.SharedFile.Replace(temp, file);
    }

    private void RemoveLocked((string Lane, string Resource) claim)
    {
        _claims.Remove(claim);
        if (Read(claim.Lane, claim.Resource)?.ManagedByDevStack == true)
        {
            File.Delete(PathOf(claim.Lane, claim.Resource));
        }
    }

    private static DateTimeOffset? ParseTime(string? value) =>
        DateTimeOffset.TryParse(value, CultureInfo.InvariantCulture, DateTimeStyles.AssumeLocal, out var t) ? t : null;

    private static bool Same(string? a, string b) => a != null && string.Equals(Normalized(a), Normalized(b), StringComparison.OrdinalIgnoreCase);

    /// <summary>A lane's lease holder was "env:&lt;lane&gt;" before the lane vocabulary; claims written then still name it so.</summary>
    private static string Normalized(string owner)
    {
        var trimmed = owner.Trim();
        return trimmed.StartsWith("env:", StringComparison.Ordinal) ? "lane:" + trimmed[4..] : trimmed;
    }
}
