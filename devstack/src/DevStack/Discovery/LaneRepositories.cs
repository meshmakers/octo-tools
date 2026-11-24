namespace Meshmakers.Octo.DevStack.Discovery;

/// <summary>
///     Whether a lane holds repositories the way octo-tools sees them (Get-OctoBuildOrder): folders named octo-* or mm-*,
///     except the developer tools that sit next to octo-tools (<see cref="DeveloperTools"/>). A build or test run in a lane
///     without one fails at once in the cmdlet, so the daemon refuses it before it creates a job (AB#8915), and a finished
///     job whose lane is gone or empty is marked as gone in the listings.
/// </summary>
public static class LaneRepositories
{
    /// <summary>
    ///     Folders named octo-* that are developer tools, not OctoMesh repositories. After the move to the lanes layout the old
    ///     flat root holds only these (and other folders); counted as repositories, its old failed jobs would stay current
    ///     failures for ever. Get-OctoBuildOrder leaves out octo-tools and octo-devstack the same way (octo-claude-pm not yet).
    /// </summary>
    public static readonly IReadOnlySet<string> DeveloperTools =
        new HashSet<string>(["octo-tools", "octo-devstack", "octo-claude-pm"], StringComparer.OrdinalIgnoreCase);

    /// <summary>Whether a folder name is a repository of a lane: octo-* or mm-*, and no developer tool.</summary>
    public static bool IsRepositoryName(string? name) =>
        name != null && (name.StartsWith("octo-", StringComparison.Ordinal) || name.StartsWith("mm-", StringComparison.Ordinal)) && !DeveloperTools.Contains(name);

    /// <summary>
    ///     True when <paramref name="lane"/> exists and holds at least one folder named octo-* or mm-* that is no developer tool,
    ///     or - for a test run of a consumer app (energy-community, voest-app) - a git repository named exactly
    ///     <paramref name="repo"/>, which Invoke-OctoTestRun accepts too.
    /// </summary>
    public static bool Holds(string lane, string? repo = null)
    {
        if (!Directory.Exists(lane))
        {
            return false;
        }

        if (!string.IsNullOrWhiteSpace(repo) && Path.GetFileName(repo.Trim()) == repo.Trim() && !DeveloperTools.Contains(repo.Trim()) &&
            Path.Exists(Path.Combine(lane, repo.Trim(), ".git")))
        {
            return true;
        }

        try
        {
            return Directory.EnumerateDirectories(lane).Select(Path.GetFileName).Any(IsRepositoryName);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            return false;
        }
    }

    /// <summary>
    ///     Throws when <paramref name="lane"/> holds no repository: the message names the folder and points to lane_build /
    ///     lane_test or to <paramref name="defaultCheckout"/>. <paramref name="what"/> names the request ("base_test", "base_build kind=range").
    /// </summary>
    public static void Require(string lane, string defaultCheckout, string what, string? repo = null)
    {
        if (Holds(lane, repo))
        {
            return;
        }

        throw new ArgumentException(
            $"{what} refused: {lane} holds no repository (no folder named octo-* or mm-* besides the developer tools {string.Join(", ", DeveloperTools.Order(StringComparer.Ordinal))}), so no job was created. " +
            $"A lane (lane_list) builds and tests with lane_build / lane_test; a base lane folder that holds the repositories is e.g. baseLane={defaultCheckout} " +
            "(the default when baseLane is left out). A git worktree of a single repository is no base lane: build it with base_build kind=repo path=<worktree>.");
    }

    /// <summary>
    ///     Why a finished job's place no longer exists, or null when it still does: the feature environment (its manifest), the
    ///     lane (missing or without repositories), or for kind=repo the repository folder (also inside an environment).
    ///     <paramref name="environment"/> is the job's environment: asked for with env=, or detected from a checkout that is
    ///     an environment folder (<see cref="Builds.PlannedBuild"/>.Environment) - its repos may lie outside the folder, so
    ///     the lane rule must not judge it. <paramref name="environmentPath"/> is its folder (the manifest).
    /// </summary>
    public static string? GoneReason(string? environment, string? environmentPath, string? lane, string kind, string target, string? repo = null)
    {
        if (environment != null)
        {
            if (environmentPath != null && !File.Exists(EnvironmentDiscovery.ManifestPath(environmentPath)))
            {
                return $"lane {environment} no longer exists ({environmentPath})";
            }

            // The environment is there, but the repo a kind=repo build built may have been removed from it.
            return kind == "repo" && !Directory.Exists(target) ? $"repository {target} of lane {environment} no longer exists" : null;
        }

        if (kind == "repo")
        {
            return Directory.Exists(target) ? null : $"folder {target} no longer exists";
        }

        if (lane == null)
        {
            return null;
        }

        if (!Directory.Exists(lane))
        {
            return $"base lane {lane} no longer exists";
        }

        return Holds(lane, kind == "test" ? repo : null) ? null : $"base lane {lane} holds no repository any more";
    }
}
