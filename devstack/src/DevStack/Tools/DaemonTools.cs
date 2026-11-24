using System.ComponentModel;
using Meshmakers.Octo.DevStack.Builds;
using Meshmakers.Octo.DevStack.Leasing;
using Meshmakers.Octo.DevStack.Runtime;
using ModelContextProtocol.Server;

namespace Meshmakers.Octo.DevStack.Tools;

/// <summary>The daemon itself: what runs, and whether it may be restarted.</summary>
[McpServerToolType]
public sealed class DaemonTools(DaemonJournal journal, BuildQueue builds, LeaseRegistry leases, DockerVm docker)
{
    [McpServerTool(Name = "daemon_status", ReadOnly = true)]
    [Description("Shows the daemon itself: pid, start time, version and commit of the running binaries, whether it is a development daemon; " +
                 "restart.safe = no job runs or waits (blockers name the jobs and their owners; a running job would go on and be " +
                 "re-attached by the next start, a queued one is restored, but their sessions wait for them now), restart.warnings name the " +
                 "owners holding a stack lease (kept across a restart); history = the last starts and stops with their trigger " +
                 "(signal name; 'lost' = a run that was killed or crashed). Check it before the shared daemon is restarted: restart it " +
                 "only when safe is true or the developer says so. docker = what Docker has to work with (docker info: memoryGb, cpus of " +
                 "its VM), whether the kind cluster runs in it, and a warning when it is below the configured dockerVm limits (default 12 GiB / " +
                 "6 CPUs) with kind running - test projects that start containers may then fail for lack of resources. The same document is " +
                 "GET /api/daemon. Read-only.")]
    public DaemonStatus Status() => ToolGuard.Run(() => journal.Status(builds, leases, docker));
}
