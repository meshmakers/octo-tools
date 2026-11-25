using System.ComponentModel;
using Meshmakers.Octo.DevStack.Builds;
using Meshmakers.Octo.DevStack.Configuration;
using Meshmakers.Octo.DevStack.Runtime;
using Meshmakers.Octo.DevStack.Ui;
using ModelContextProtocol.Server;

namespace Meshmakers.Octo.DevStack.Tools;

/// <summary>
///     What the status page reads over its JSON endpoints and no other tool returned: every read endpoint of the page has a
///     tool, and every read-only tool is GET /api/tools/{name} (<see cref="ToolBridge"/>).
/// </summary>
[McpServerToolType]
public sealed class StatusPageTools(StackSupervisor supervisor, BuildQueue builds, ConfigStore store, EnvironmentManager environments, SlotOperations operations)
{
    [McpServerTool(Name = "stack_attention", ReadOnly = true)]
    [Description("Lists what needs attention, worst first - the list at the top of the status page (/api/overview attention): services that " +
                 "exited or do not answer (the shared stack and every lane stack), services running another build than their folder holds, " +
                 "broken lanes, the newest job of a target when it failed or lost its process (it clears once a newer run of the same target " +
                 "succeeds - a failed build of repos also once later range or all builds of the same base lane built each of them; a run in a " +
                 "lane is another target than the same repo in the base lane; a job whose lane or folder is gone, or holds only the developer " +
                 "tools octo-tools, octo-devstack and octo-claude-pm, is history and never listed), running jobs whose repo or test project " +
                 "runs far longer than usual (overdue: beyond limitSeconds of job_stats - it probably hangs), refused builds, profile drift " +
                 "of the shared stack, and processes on service ports the daemon did not start. Per item: level stop|caution|foreign, kind " +
                 "config|service|lane|build|test|overdue|refusal|drift|external, the text, slot/service/buildId, and hint = the call " +
                 "that explains it. An empty list means nothing needs attention. Read-only.")]
    public Task<IReadOnlyList<AttentionItem>> Attention() =>
        ToolGuard.Run(async () => (await Overview.BuildAsync(supervisor, builds, store, environments)).Attention);

    [McpServerTool(Name = "job_refusals", ReadOnly = true)]
    [Description("Lists the builds refused in the last 2 hours, newest first, until a later build of the same target was queued: who asked (owner), " +
                 "kind, target, reason and the conflicts (running services and who started them). The status page shows them as " +
                 "'refused' (/api/overview buildRefusals). Read-only.")]
    public IReadOnlyList<BuildRefusal> Refusals() => builds.Refusals();

    [McpServerTool(Name = "admin_config_inspect", ReadOnly = true)]
    [Description("Admin: shows the configuration as the status page's config view does (GET /api/config): every service with what it resolves " +
                 "to in the base lane (repo path, working directory, problem), every profile with its extends chain, its own fields and the " +
                 "merged result, the slots with the ports of every service and their evaluated slotDerivations, retired slot indexes, the " +
                 "lanes' manifests and the daemon's paths. config_get is the configuration as written. Secret-looking values are masked. Read-only.")]
    public Task<ConfigInspection> Inspect() => ToolGuard.Run(() => ConfigInspector.BuildAsync(store, supervisor, operations));

    [McpServerTool(Name = "job_output", ReadOnly = true)]
    [Description("Shows the output of a job - a build or a test run (GET /api/builds/{id}/output): its repos (failed first) with state, durations " +
                 "and parsed errors, and the last lines of one repo's log (repo=X, also after the build from the log the daemon kept) or of the " +
                 "job log. job_status(live=N) gives at most 200 lines; this gives up to 5000. Read-only.")]
    public BuildOutput Output(
        [Description(BuildTools.IdDescription)] string id,
        [Description("Only this repo's log; omit for the job log.")] string? repo = null,
        [Description("Number of lines (default 400, max 5000).")] int lines = 400) =>
        ToolGuard.Run(() => builds.Output(id, string.IsNullOrWhiteSpace(repo) ? null : repo, Math.Clamp(lines, 1, 5000)));
}
