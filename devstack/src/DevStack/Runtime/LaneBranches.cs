using System.ComponentModel;
using System.Text.Json.Serialization;
using Meshmakers.Octo.DevStack.Common;
using Meshmakers.Octo.DevStack.Discovery;

namespace Meshmakers.Octo.DevStack.Runtime;

/// <summary>
///     lane_remove: a feature branch the removed lane left as a local ref in the repository its worktree belonged to (repoPath,
///     usually the base lane's checkout of the repo). deleted: it held no commit beyond its base commit; otherwise reason says
///     why it stays and delete is the command to remove it once its work is merged.
/// </summary>
public sealed record LaneBranch(string Repo, string Branch, string RepoPath, bool Deleted, string Reason)
{
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public string? Delete { get; init; }
}

/// <summary>
///     The feature branches of a lane after Remove-OctoEnvironment, which removes the worktrees but keeps their branches. A
///     branch with no commit beyond its base commit holds nothing and is deleted in the repository that owns it; a branch with
///     commits stays and is listed with the command for after the merge. Never deleted: the base branch (the lane's baseRef,
///     origin's default branch), a branch checked out in any worktree, a branch whose commit no other ref holds. git as a
///     process (<see cref="GitProcess"/>); tests use temp repositories.
/// </summary>
internal static class LaneBranches
{
    private static readonly TimeSpan Timeout = TimeSpan.FromSeconds(30);

    /// <summary>A feature branch of the lane and the repository that holds its ref, read before the worktrees go.</summary>
    internal sealed record Target(string Repo, string Branch, string? BaseCommit, string? BaseRef, string RepoPath)
    {
        /// <summary>Why the repository the worktree belonged to is unknown (then RepoPath is the worktree): the branch is only reported.</summary>
        public string? OwnerUnknown { get; init; }
    }

    /// <summary>
    ///     The feature branches of the lane's own worktrees (in-place worktrees stay, and so do their branches) with the
    ///     repository each belongs to: git's common directory of the worktree, else the base lane's checkout of the repo. Never throws.
    /// </summary>
    public static async Task<List<Target>> TargetsAsync(EnvironmentInfo env)
    {
        var targets = new List<Target>();
        foreach (var repo in env.Manifest?.Repos ?? [])
        {
            if (string.IsNullOrWhiteSpace(repo.Branch) || !PathScope.IsUnder(repo.Path, env.Path))
            {
                continue;
            }

            var (owner, unknown) = await OwningRepositoryAsync(repo.Path);
            if (owner == null && unknown == null && env.BasePath is { } basePath && Directory.Exists(Path.Combine(basePath, repo.Name, ".git")))
            {
                owner = Path.Combine(basePath, repo.Name); // the worktree is gone already: the base lane's clone is where octo-tools made it
            }

            if (owner != null)
            {
                targets.Add(new Target(repo.Name, repo.Branch.Trim(), repo.BaseCommit, repo.BaseRef, owner));
            }
            else if (unknown != null)
            {
                // The worktree is there but git cannot say whose it is: reported, never deleted (another repository may hold a same-named branch).
                targets.Add(new Target(repo.Name, repo.Branch.Trim(), repo.BaseCommit, repo.BaseRef, repo.Path) { OwnerUnknown = unknown });
            }
        }

        return targets;
    }

    /// <summary>
    ///     The main working tree of the repository a worktree belongs to (the parent of git's common .git directory). Owner null
    ///     and Unknown null: the worktree has no .git (gone); Unknown set: it has one, but git could not tell its repository.
    /// </summary>
    private static async Task<(string? Owner, string? Unknown)> OwningRepositoryAsync(string worktree)
    {
        if (!File.Exists(Path.Combine(worktree, ".git")) && !Directory.Exists(Path.Combine(worktree, ".git")))
        {
            return (null, null);
        }

        var (exitCode, output, error) = await TryGitAsync(worktree, "rev-parse", "--git-common-dir");
        if (exitCode != 0 || output.Trim() is not { Length: > 0 } common)
        {
            return (null, $"git rev-parse --git-common-dir in {worktree}: {GitProcess.FirstLine(error)}");
        }

        var full = Path.GetFullPath(Path.IsPathRooted(common) ? common : Path.Combine(worktree, common)).TrimEnd(Path.DirectorySeparatorChar, '/');
        return Path.GetFileName(full) == ".git" ? (Path.GetDirectoryName(full), null) : (null, $"its git directory {full} is not a repository's .git");
    }

    /// <summary>Deletes the branches that hold nothing and lists every one; <paramref name="keepAll"/> (keepBranches) deletes none. Never throws.</summary>
    public static async Task<List<LaneBranch>> CleanAsync(IReadOnlyList<Target> targets, bool keepAll)
    {
        var result = new List<LaneBranch>();
        foreach (var target in targets)
        {
            if (await CleanAsync(target, keepAll) is { } branch)
            {
                result.Add(branch);
            }
        }

        return result;
    }

    /// <summary>One branch; null when its ref is gone already (nothing to report).</summary>
    private static async Task<LaneBranch?> CleanAsync(Target target, bool keepAll)
    {
        var deleteCommand = Quote(target.RepoPath) is { } repoArg && Quote(target.Branch) is { } branchArg ? $"git -C {repoArg} branch -D {branchArg}" : null;
        LaneBranch Kept(string reason, bool withCommand = true) =>
            new(target.Repo, target.Branch, target.RepoPath, false, reason) { Delete = withCommand ? deleteCommand : null };

        if (target.OwnerUnknown is { } why)
        {
            return Kept($"the repository its worktree belonged to could not be read ({why}); the daemon deletes no branch in another repository", withCommand: false);
        }

        var (tipExit, tipOutput, tipError) = await TryGitAsync(target.RepoPath, "rev-parse", "--verify", "--quiet", $"refs/heads/{target.Branch}^{{commit}}");
        if (tipExit != 0)
        {
            // No such branch (any more): quiet --verify fails without a message; anything else is a problem worth naming.
            return tipError.Trim().Length == 0 ? null : Kept($"git could not read the branch: {GitProcess.FirstLine(tipError)}");
        }

        var tip = tipOutput.Trim();
        if (keepAll)
        {
            return Kept("keepBranches=true keeps every branch of the lane");
        }

        if (IsBaseBranch(target) || await DefaultBranchAsync(target.RepoPath) == target.Branch)
        {
            return Kept("it is the base branch; the daemon never deletes it", withCommand: false);
        }

        if (await CheckedOutAsync(target.RepoPath, target.Branch) is { } worktree)
        {
            return Kept($"it is checked out in {worktree}; the daemon never deletes a branch checked out anywhere", withCommand: false);
        }

        if (string.IsNullOrWhiteSpace(target.BaseCommit))
        {
            return Kept("the lane's manifest names no base commit for it, so the daemon cannot tell whether it holds work");
        }

        var (countExit, countOutput, countError) = await TryGitAsync(target.RepoPath, "rev-list", "--count", $"{target.BaseCommit}..{tip}");
        if (countExit != 0 || !int.TryParse(countOutput.Trim(), out var ahead))
        {
            return Kept($"git could not compare it with its base commit {Short(target.BaseCommit)}: {GitProcess.FirstLine(countError)}");
        }

        if (ahead > 0)
        {
            return Kept($"it holds {ahead} commit(s) beyond its base commit {Short(target.BaseCommit)}; delete it once they are merged " +
                        "(-D: after a squash merge git branch -d does not see them as merged)");
        }

        // No commit of its own. Its commit must stay reachable without it (on origin or another branch): git branch -d would
        // only ask the base lane's HEAD, which may lag behind the commit the lane started from.
        var (refsExit, refsOutput, _) = await TryGitAsync(target.RepoPath, "for-each-ref", "--contains", tip, "--format=%(refname)");
        if (refsExit != 0 || !refsOutput.Split('\n').Select(r => r.Trim()).Any(r => r.Length > 0 && r != $"refs/heads/{target.Branch}"))
        {
            return Kept($"its commit {Short(tip)} is on no other branch or remote; the daemon keeps it");
        }

        // Deleted only while it still points at the commit inspected above: a branch another git call advanced meanwhile stays
        // (update-ref compares the old value under the ref's lock; the checks above already refused a checked-out branch).
        var (deleteExit, _, deleteError) = await TryGitAsync(target.RepoPath, "update-ref", "-d", $"refs/heads/{target.Branch}", tip);
        if (deleteExit == 0)
        {
            // What git branch -D also removes: the branch's own configuration (upstream); none is fine.
            await TryGitAsync(target.RepoPath, "config", "--remove-section", $"branch.{target.Branch}");
        }

        return deleteExit == 0
            ? new LaneBranch(target.Repo, target.Branch, target.RepoPath, true, $"it held no commit beyond its base commit {Short(target.BaseCommit)} (was {Short(tip)})")
            : Kept($"git could not delete it (it changed after the check, or: {GitProcess.FirstLine(deleteError)})");
    }

    /// <summary>
    ///     A value for a command the developer pastes into a shell (POSIX shells and PowerShell): in single quotes, where neither
    ///     expands anything. Null for a value with a single quote or a control character: no command is offered for it then.
    /// </summary>
    internal static string? Quote(string value) =>
        value.Any(c => c == '\'' || char.IsControl(c)) ? null : $"'{value}'";

    /// <summary>The lane's base branch: its baseRef without the remote ('origin/main' is main).</summary>
    private static bool IsBaseBranch(Target target)
    {
        if (string.IsNullOrWhiteSpace(target.BaseRef) || target.BaseRef == "HEAD")
        {
            return false;
        }

        var name = target.BaseRef.Trim();
        foreach (var prefix in new[] { "refs/heads/", "refs/remotes/origin/", "origin/" })
        {
            if (name.StartsWith(prefix, StringComparison.Ordinal))
            {
                name = name[prefix.Length..];
                break;
            }
        }

        return name == target.Branch;
    }

    /// <summary>origin's default branch (refs/remotes/origin/HEAD), or null.</summary>
    private static async Task<string?> DefaultBranchAsync(string repository)
    {
        var (exitCode, output, _) = await TryGitAsync(repository, "symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD");
        var name = output.Trim();
        return exitCode == 0 && name.StartsWith("origin/", StringComparison.Ordinal) ? name["origin/".Length..] : null;
    }

    /// <summary>The worktree (the main one included) that has <paramref name="branch"/> checked out, or null.</summary>
    private static async Task<string?> CheckedOutAsync(string repository, string branch)
    {
        var (exitCode, output, _) = await TryGitAsync(repository, "worktree", "list", "--porcelain");
        if (exitCode != 0)
        {
            return repository; // unknown: treat it as checked out
        }

        string? path = null;
        foreach (var line in output.Split('\n').Select(l => l.TrimEnd('\r')))
        {
            if (line.StartsWith("worktree ", StringComparison.Ordinal))
            {
                path = line["worktree ".Length..];
            }
            else if (line == $"branch refs/heads/{branch}")
            {
                return path ?? repository;
            }
        }

        return null;
    }

    private static string Short(string sha) => sha.Length > 10 ? sha[..10] : sha;

    private static async Task<(int ExitCode, string Output, string Error)> TryGitAsync(string folder, params string[] arguments)
    {
        try
        {
            return await GitProcess.RunAsync(folder, arguments, Timeout);
        }
        catch (Exception e) when (e is Win32Exception or IOException or InvalidOperationException or TimeoutException)
        {
            return (-1, "", e.Message);
        }
    }
}
