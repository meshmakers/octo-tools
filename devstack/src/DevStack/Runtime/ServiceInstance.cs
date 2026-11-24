using System.Diagnostics;
using Meshmakers.Octo.DevStack.Configuration;

namespace Meshmakers.Octo.DevStack.Runtime;

/// <summary>
///     Who made a service run the way it runs now: the owner of the call that chose its source and overrides - stack_start,
///     service_start, or a service_restart that passed overrides for it. A restart that keeps the overrides, or the start after
///     a build that stopped it, keeps the origin: whom to ask about the service is who decided what it runs, not who only
///     bounced it. <see cref="Via"/> names that call.
/// </summary>
public sealed record ServiceOrigin(string Owner, string Via)
{
    /// <summary>The ListAgents name the caller passed (null: none given), so another session can SendMessage it.</summary>
    public string? Session { get; init; }

    public const string StackStart = "stack_start";
    public const string ServiceStart = "service_start";
    public const string ServiceRestart = "service_restart";

    /// <summary>A start after a build whose stopped service had no origin recorded (an older state file).</summary>
    public const string AfterBuild = "restart after a build";
}

/// <summary>
///     Who makes a call that starts services, for the attribution of what it starts (<see cref="ServiceOrigin"/>, the stack's
///     startedBy). In a lane stack the lease is the lane's (lane:&lt;name&gt;), but the services are started by this caller.
/// </summary>
public sealed record StackCaller(string Owner, string? Session = null)
{
    public ServiceOrigin Origin(string via) => new(Owner, via) { Session = string.IsNullOrWhiteSpace(Session) ? null : Session.Trim() };
}

/// <summary>A running (or crashed) service process of the stack.</summary>
public sealed class ServiceInstance
{
    private readonly Process? _process;

    public ServiceInstance(ServicePlan plan, Process process, ServiceOverride? overrides)
    {
        Plan = plan;
        Pid = process.Id;
        StartedAt = DateTimeOffset.Now;
        ProcessStartTime = Common.ProcessTree.StartTime(process);
        Override = overrides;
        _process = process;
        process.EnableRaisingEvents = true;
        process.Exited += (_, _) =>
        {
            ExitedAt = DateTimeOffset.Now;
            try
            {
                ExitCode = process.ExitCode;
            }
            catch (InvalidOperationException)
            {
                ExitCode = null;
            }
        };
        if (process.HasExited && ExitedAt == null)
        {
            ExitedAt = DateTimeOffset.Now;
            ExitCode = process.ExitCode;
        }
    }

    /// <summary>A process found in the state file after a daemon restart.</summary>
    public ServiceInstance(ServicePlan plan, int pid, DateTimeOffset startedAt, DateTimeOffset? processStartTime = null)
    {
        Plan = plan;
        Pid = pid;
        StartedAt = startedAt;
        ProcessStartTime = processStartTime;
        Adopted = true;
    }

    public ServicePlan Plan { get; }
    public int Pid { get; }
    public DateTimeOffset StartedAt { get; }
    public ServiceOverride? Override { get; }

    /// <summary>Who started or overrode the service (null: not known, e.g. adopted from a state file that has no starter).</summary>
    public ServiceOrigin? Origin { get; init; }

    /// <summary>The start time the OS reports for <see cref="Pid"/>; tells a reused pid from the process the daemon started.</summary>
    public DateTimeOffset? ProcessStartTime { get; }

    /// <summary>Started by an earlier daemon process; no exit code is available.</summary>
    public bool Adopted { get; }

    public DateTimeOffset? ExitedAt { get; private set; }
    public int? ExitCode { get; private set; }

    public bool IsAlive
    {
        get
        {
            if (_process != null)
            {
                return !_process.HasExited;
            }

            var alive = Common.ProcessTree.IsAlive(Pid, ProcessStartTime);
            if (!alive && ExitedAt == null)
            {
                ExitedAt = DateTimeOffset.Now;
            }

            return alive;
        }
    }

    public Task WaitForExitAsync(CancellationToken cancellationToken) =>
        _process?.WaitForExitAsync(cancellationToken) ?? Task.CompletedTask;
}
