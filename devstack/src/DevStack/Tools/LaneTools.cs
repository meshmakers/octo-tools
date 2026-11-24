using System.ComponentModel;
using Meshmakers.Octo.DevStack.Runtime;
using ModelContextProtocol.Server;

namespace Meshmakers.Octo.DevStack.Tools;

/// <summary>Lanes (octo-tools: feature environments): listed by the daemon, created, changed and removed by the octo-tools cmdlets.</summary>
[McpServerToolType]
public sealed class LaneTools(EnvironmentManager environments)
{
    private const string LaneName = "Lane name (lane_list).";

    [McpServerTool(Name = "lane_list", ReadOnly = true)]
    [Description("Lists the lanes - the workspaces of one work item each (octo-tools: feature environments, <rootPath>/wt-<lane> with a manifest): " +
                 "name, work item, base lane, owner, repos with their paths (feature: own branch; consumer: detached at the base commit; a path " +
                 "may lie outside the folder when a worktree was adopted in place) - edit there -, the lane's stack with health and lease (held " +
                 "by 'lane:<name>', with the session that changed it last, lastActivityAt and idleMinutes), queued/running jobs, inSharedStack " +
                 "(the shared stack's services that run the lane's build now, source 'lane:<name>'), and a problem when the manifest cannot be used. " +
                 "With lane: that lane only, plus Get-OctoEnvironment's details (per repo exists, dirty, unpushed, role, path, branch). Pass " +
                 "the name as lane to lane_build, lane_test, stack_*, service_* and job_cancel. Read-only.")]
    public Task<List<EnvironmentRow>> List(
        [Description("One lane, with octo-tools' details per repo.")] string? lane = null,
        CancellationToken cancellationToken = default) =>
        ToolGuard.Run(() => environments.ListAsync(lane, cancellationToken));

    [McpServerTool(Name = "lane_create")]
    [Description("Creates the lane of a work item with octo-tools New-OctoEnvironment: <rootPath>/wt-<lane> with feature worktrees of the given " +
                 "repos on 'branch', its own Octo.User.props (own package cache), a snapshot of the base lane's feed and catalogs, the manifest " +
                 "and its own stack slot; the package cache is filled from a local cache (a note says how much, how and how long). Nothing " +
                 "builds or runs yet. The flow: edit in the paths lane_list shows, lane_build(lane), lane_test(lane, repo), stack_start(lane), " +
                 "verify, lane_remove(lane) after the merge. The name also names the lane's stack (lowercase letters, digits, '-'). Refused while " +
                 "the daemon's octo-tools lacks the cmdlet.")]
    public Task<EnvironmentCommandResult> Create(
        [Description(StackTools.OwnerDescription)] string owner,
        [Description("Lane name (slug), e.g. 'ab8625-enum-null'.")] string lane,
        [Description("Repos to change (feature worktrees), e.g. ['octo-sdk'].")] List<string>? repos = null,
        [Description("Git branch of the feature worktrees, e.g. '<user>/AB#8625_enum-null' (default: the cmdlet's).")] string? branch = null,
        [Description("Work item, e.g. 'AB#8625'.")] string? workItem = null,
        [Description(StackTools.SessionDescription)] string? session = null,
        [Description("Also add the repos affected by the feature repos as consumer worktrees (rebuilt against them).")] bool addAffected = false,
        [Description("Do not fill the lane's package cache from a local cache (filled by default, so the first build downloads nothing; " +
                     "admin_lane_seed_cache does it later).")]
        bool skipPackageCacheSeed = false,
        CancellationToken cancellationToken = default) =>
        ToolGuard.Run(async () =>
        {
            using var caller = StackTools.Caller(session, owner, lane);
            return await environments.CreateAsync(owner, lane, repos ?? [], workItem, branch, addAffected, cancellationToken, skipPackageCacheSeed);
        });

    [McpServerTool(Name = "lane_add_repo")]
    [Description("Adds a repo to a lane with octo-tools Add-OctoEnvironmentRepo: 'repo' creates a feature worktree (or a consumer one, detached at " +
                 "the base commit, with role=consumer; addAffected also adds the repos that consume it), 'path' adopts an existing worktree (a " +
                 "flat wt-<lane>-<repo> or <repo>/.claude/worktrees/<name>; inPlace keeps it where it is). Refused while the lane builds or a " +
                 "service of that repo runs in the lane's stack (stop it first). Build afterwards with lane_build.")]
    public Task<EnvironmentCommandResult> AddRepo(
        [Description(StackTools.OwnerDescription)] string owner,
        [Description(LaneName)] string lane,
        [Description("Repo to add as a new worktree, e.g. 'octo-sdk'.")] string? repo = null,
        [Description("An existing worktree to adopt instead of repo (absolute, or relative to rootPath).")] string? path = null,
        [Description("'feature' (own branch) or 'consumer' (detached at the base commit); default: the cmdlet's.")] string? role = null,
        [Description("Also add the repos affected by it as consumers.")] bool addAffected = false,
        [Description("With path: adopt the worktree where it is instead of moving it.")] bool inPlace = false,
        [Description(StackTools.SessionDescription)] string? session = null,
        CancellationToken cancellationToken = default) =>
        ToolGuard.Run(async () =>
        {
            using var caller = StackTools.Caller(session, owner, lane);
            return await environments.AddRepoAsync(owner, lane, repo, path, role, addAffected, inPlace, cancellationToken);
        });

    [McpServerTool(Name = "lane_sync")]
    [Description("Refreshes a lane's snapshot of the base lane's packages and catalogs with octo-tools Sync-OctoEnvironment (packages the lane " +
                 "built win) - after a library change was merged and built into the base lane. Refused while a range/all build of the base lane " +
                 "runs or waits (it would copy a half-built feed) and while the lane builds. lane_build(syncMain=true) does the same first.")]
    public Task<EnvironmentCommandResult> Sync(
        [Description(StackTools.OwnerDescription)] string owner,
        [Description(LaneName)] string lane,
        [Description(StackTools.SessionDescription)] string? session = null,
        CancellationToken cancellationToken = default) =>
        ToolGuard.Run(async () =>
        {
            using var caller = StackTools.Caller(session, owner, lane);
            return await environments.SyncAsync(owner, lane, cancellationToken);
        });

    [McpServerTool(Name = "lane_affected", ReadOnly = true)]
    [Description("Lists the repos a lane's changes reach (octo-tools Get-OctoAffectedRepos: package graph from the csproj files, transitive " +
                 "consumers of the feature repos, the ones on the path to 'target') - candidates for lane_add_repo role=consumer. Read-only.")]
    public Task<EnvironmentCommandResult> Affected(
        [Description(LaneName)] string lane,
        [Description("Only the repos on the path to this repo or service repo, e.g. 'octo-asset-repo-services'.")] string? target = null,
        CancellationToken cancellationToken = default) =>
        ToolGuard.Run(() => environments.AffectedAsync(lane, target, cancellationToken));

    [McpServerTool(Name = "admin_lane_seed_cache")]
    [Description("Admin: fills or tops up the package cache of an existing lane from a local package cache with octo-tools " +
                 "Initialize-OctoEnvironmentPackageCache (clone where the file system can, else copy; local 999.0.0 builds and incomplete packages " +
                 "are left out), so its next build restores without downloading. For lanes created before octo-tools AB#8831, which start with " +
                 "an empty cache; safe to repeat (packages already there are kept). The answer says how many package versions, the size, the " +
                 "method and the time. dryRun=true only reports. Refused while the lane builds or tests.")]
    public Task<EnvironmentCommandResult> SeedCache(
        [Description(StackTools.OwnerDescription)] string owner,
        [Description(LaneName)] string lane,
        [Description("Only report what would be taken (-WhatIf).")] bool dryRun = false,
        [Description(StackTools.SessionDescription)] string? session = null,
        CancellationToken cancellationToken = default) =>
        ToolGuard.Run(async () =>
        {
            using var caller = StackTools.Caller(session, owner, lane);
            return await environments.SeedCacheAsync(owner, lane, dryRun, cancellationToken);
        });

    [McpServerTool(Name = "lane_remove", Destructive = true)]
    [Description("Removes a lane after its work is merged, leaving nothing behind. While it runs the lane is marked as being removed (lane_list: " +
                 "removing): every changing call on it from any session - stack, build, test, lane_* - is refused. First it checks which processes hold files below the lane " +
                 "folder: the lane stack's own services are stopped, anything else - an MSBuild node a plain `dotnet build` left running, a shell, " +
                 "an IDE, a service of another stack running the lane's build - refuses the removal with that list (pid, name, start time) and how " +
                 "to stop them, and nothing is changed. Then it stops the lane's stack, releases its lease and octo-tools Remove-OctoEnvironment " +
                 "removes the worktrees and the folder (it refuses dirty or unpushed worktrees; there is no force: commit and push, or discard, the " +
                 "work first). Afterwards the daemon drops the lane stack's data: system, tenant and Hangfire databases, RabbitMQ queues and " +
                 "exchanges, CrateDB schemas, the octo-cli installation entry and contexts, the stack's state folder and the lane's secret files; " +
                 "'dataDrop' reports every step. When every step succeeded the stack's slot index is free again; otherwise it stays retired and " +
                 "'leftovers' lists what remains (admin_slot_drop_data tries again). S3 artifacts are not checked, only listed; that blocks nothing. " +
                 "The lane's feature branches (Remove-OctoEnvironment keeps them as local refs in the base lane's checkouts): one without a commit " +
                 "beyond its base commit is deleted, one with commits stays - 'branches' lists each with the reason and the command to delete it " +
                 "after the merge. Refused while a job of the lane runs or waits, or another session holds the lane stack's lease.")]
    public Task<EnvironmentCommandResult> Remove(
        [Description(StackTools.OwnerDescription)] string owner,
        [Description(LaneName)] string lane,
        [Description(StackTools.SessionDescription)] string? session = null,
        [Description("true: keep the lane stack's data; its slot index stays retired (no new stack finds the data) until admin_slot_drop_data drops it. The lane's secret files go all the same (a failed deletion is listed in leftovers).")]
        bool keepData = false,
        [Description("true: keep every feature branch of the lane, also the ones without commits (they are listed in 'branches').")]
        bool keepBranches = false,
        CancellationToken cancellationToken = default) =>
        ToolGuard.Run(async () =>
        {
            using var caller = StackTools.Caller(session, owner, lane);
            return await environments.RemoveAsync(owner, lane, keepData, cancellationToken, keepBranches);
        });
}
