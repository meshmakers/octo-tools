using System.Reflection;
using System.Text.Json;
using System.Text.Json.Serialization;
using Meshmakers.Octo.DevStack.Builds;
using Meshmakers.Octo.DevStack.Common;
using Meshmakers.Octo.DevStack.Leasing;

namespace Meshmakers.Octo.DevStack.Runtime;

/// <summary>
///     One start or stop of the daemon. event: start | stop | lost (a run that left no stop record: killed or crashed;
///     written by the next start). trigger: what ended the run (the signal's name, or "host shutdown").
/// </summary>
public sealed record DaemonEvent(
    DateTimeOffset At,
    string Event,
    int Pid,
    string Version,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    string? Commit,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    string? Trigger = null,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    string? Detail = null);

/// <summary>The running daemon: what it was built from and where it listens.</summary>
public sealed record DaemonProcess(
    int Pid,
    DateTimeOffset StartedAt,
    string Version,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    string? Commit,
    string Configuration,
    string Binary,
    DateTimeOffset BinaryWrittenAt,
    string Url,
    string ConfigPath,
    string StateDirectory,
    bool Development);

/// <summary>A held stack lease, for the restart check.</summary>
public sealed record HeldLease(string Slot, string Owner, [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)] string? Purpose, DateTimeOffset ExpiresAt);

/// <summary>
///     Whether the daemon may be restarted now. safe = no build runs or waits. blockers say why not; warnings name the
///     sessions that hold a lease (they keep it across the restart, but a tool call of theirs in flight fails).
/// </summary>
public sealed record RestartCheck(bool Safe, IReadOnlyList<string> Blockers, IReadOnlyList<string> Warnings, IReadOnlyList<ActiveBuild> Builds,
    IReadOnlyList<HeldLease> Leases);

public sealed record DaemonStatus(DaemonProcess Daemon, RestartCheck Restart, IReadOnlyList<DaemonEvent> History,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    DockerVmInfo? Docker = null);

/// <summary>
///     The daemon's own life: every start and stop goes into <c>daemon-history.jsonl</c> of the state folder (and into the
///     daemon's log), so the status page can show the last restarts and what triggered them.
/// </summary>
public sealed class DaemonJournal
{
    private const int KeptEvents = 200;

    private static readonly JsonSerializerOptions Options = new(JsonSerializerDefaults.Web) { DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull };

    private readonly string _file;
    private readonly Lock _lock = new();
    private string? _signal;
    private bool _stopped;

    public DaemonJournal(DevStackPaths paths, string url, string configPath, bool development = false, DateTimeOffset? startedAt = null)
    {
        _file = Path.Combine(paths.StateDirectory, "daemon-history.jsonl");
        var assembly = typeof(DaemonJournal).Assembly;
        var (version, commit) = SplitVersion(assembly.GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion ??
                                             assembly.GetName().Version?.ToString() ?? "0.0.0");
        var binary = assembly.Location;
        Daemon = new DaemonProcess(Environment.ProcessId, startedAt ?? DateTimeOffset.Now, version, commit,
            assembly.GetCustomAttribute<AssemblyConfigurationAttribute>()?.Configuration ?? "", binary,
            File.Exists(binary) ? new DateTimeOffset(File.GetLastWriteTime(binary)) : DateTimeOffset.Now, url, configPath, paths.StateDirectory, development);
    }

    public DaemonProcess Daemon { get; }

    /// <summary>"1.2.3+abcdef0123" -> ("1.2.3", "abcdef0123"): the SDK appends the commit the binaries were built from.</summary>
    internal static (string Version, string? Commit) SplitVersion(string informational)
    {
        var plus = informational.IndexOf('+');
        return plus < 0 ? (informational, null) : (informational[..plus], informational[(plus + 1)..] is { Length: > 0 } c ? c[..Math.Min(c.Length, 12)] : null);
    }

    /// <summary>
    ///     Records this start. A previous run without a stop record gets a "lost" event first (it was killed with SIGKILL,
    ///     crashed, or the machine went down). Returns the events written, for the log.
    /// </summary>
    public List<DaemonEvent> RecordStart()
    {
        lock (_lock)
        {
            var events = Read();
            var written = new List<DaemonEvent>();
            if (events.LastOrDefault() is { Event: "start" } previous)
            {
                written.Add(new DaemonEvent(Daemon.StartedAt, "lost", previous.Pid, previous.Version, previous.Commit, "unknown",
                    $"the run started at {previous.At.ToLocalTime():yyyy-MM-dd HH:mm:ss} left no shutdown record: it was killed (SIGKILL), crashed, or the machine went down"));
            }

            written.Add(new DaemonEvent(Daemon.StartedAt, "start", Daemon.Pid, Daemon.Version, Daemon.Commit,
                Detail: $"{Daemon.Configuration} build of {Daemon.BinaryWrittenAt.ToLocalTime():yyyy-MM-dd HH:mm:ss}, {Daemon.Url}"));
            Write(events.Concat(written).TakeLast(KeptEvents));
            return written;
        }
    }

    /// <summary>A termination signal arrived (SIGTERM, SIGINT, ...): the stop record names it.</summary>
    public void NoteSignal(string signal)
    {
        lock (_lock)
        {
            _signal ??= signal;
        }
    }

    /// <summary>Records the shutdown once. The sender of a signal is not available to a .NET process, so only its name is kept.</summary>
    public DaemonEvent? RecordStop(string? detail = null)
    {
        lock (_lock)
        {
            if (_stopped)
            {
                return null;
            }

            _stopped = true;
            var stop = new DaemonEvent(DateTimeOffset.Now, "stop", Daemon.Pid, Daemon.Version, Daemon.Commit,
                _signal != null ? $"signal {_signal}" : "host shutdown", detail);
            try
            {
                Write(Read().Append(stop).TakeLast(KeptEvents));
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException)
            {
                // The next start reports the run as lost.
            }

            return stop;
        }
    }

    /// <summary>The last events, newest first.</summary>
    public List<DaemonEvent> Recent(int count = 20)
    {
        lock (_lock)
        {
            return Read().TakeLast(Math.Clamp(count, 1, KeptEvents)).Reverse().ToList();
        }
    }

    /// <summary>The daemon, whether a restart is safe now, and its last starts and stops.</summary>
    public DaemonStatus Status(BuildQueue builds, LeaseRegistry leases, DockerVm? docker = null) =>
        new(Daemon, Check(builds.Active(), Held(leases)), Recent(), docker?.Current());

    private static List<HeldLease> Held(LeaseRegistry leases) =>
        leases.All.Select(l => (l.Slot, Holder: l.Current())).Where(x => x.Holder != null)
            .Select(x => new HeldLease(x.Slot, x.Holder!.Owner, x.Holder.Purpose, x.Holder.ExpiresAt.ToLocalTime())).ToList();

    /// <summary>The restart rule (pure): builds block, leases warn.</summary>
    public static RestartCheck Check(IReadOnlyList<ActiveBuild> builds, IReadOnlyList<HeldLease> leases)
    {
        var blockers = builds.Select(b => b.State == "queued"
            ? $"build {b.Id} of {b.Owner} ({b.Kind} {b.Target}) is queued; the next start restores it in its place"
            : b.SurvivesRestart
                ? $"build {b.Id} of {b.Owner} ({b.Kind} {b.Target}) is running (pid {b.Pid}); it would go on and be re-attached, but its owner polls it now"
                : $"build {b.Id} of {b.Owner} ({b.Kind} {b.Target}) is running{(b.Phase != null ? $" ({b.Phase} services)" : "")} and would NOT survive a restart").ToList();
        var warnings = leases.Select(l =>
            $"slot '{l.Slot}' is leased to {l.Owner}{(l.Purpose != null ? $" ({l.Purpose})" : "")} until {l.ExpiresAt:HH:mm}; the lease and the running services are kept, a tool call in flight fails").ToList();
        return new RestartCheck(blockers.Count == 0, blockers, warnings, builds, leases);
    }

    private List<DaemonEvent> Read()
    {
        var result = new List<DaemonEvent>();
        if (!File.Exists(_file))
        {
            return result;
        }

        foreach (var line in Common.SharedFile.ReadAllLines(_file))
        {
            try
            {
                if (line.Length > 0 && JsonSerializer.Deserialize<DaemonEvent>(line, Options) is { } e)
                {
                    result.Add(e);
                }
            }
            catch (JsonException)
            {
                // A half-written line of a killed daemon.
            }
        }

        return result;
    }

    private void Write(IEnumerable<DaemonEvent> events)
    {
        var temp = _file + ".tmp";
        File.WriteAllLines(temp, events.Select(e => JsonSerializer.Serialize(e, Options)));
        Common.SharedFile.Replace(temp, _file);
    }
}
