using System.Text.Json.Nodes;
using Meshmakers.Octo.DevStack.Common;

namespace Meshmakers.Octo.DevStack.Configuration;

/// <summary>The values a devstack.yaml without rootPath / defaultCheckout runs with (the base lane), and the octo-tools it uses.</summary>
public sealed record WorkspaceDefaults(string RootPath, string OctoToolsPath, string BaseLane);

/// <summary>
///     How the machine is laid out (AB#9377), as octo-tools describes it (<c>Get-OctoWorkspace -Json</c>, source
///     <c>octo-tools</c>). octo-tools is the only place that knows the layouts and the config folder: the daemon keeps no
///     rule of its own. When octo-tools is not found (source <c>none</c>) or does not answer (source <c>unanswered</c>:
///     too old, pwsh missing) the problems say why and nothing is derived.
/// </summary>
public sealed record WorkspaceInfo(
    string Source,
    string? RootPath,
    string? ToolsPath,
    string? Layout,
    string? DefaultLane,
    string? DefaultLanePath,
    string? DefaultLaneSource,
    string? ConfigDirectory,
    bool? ToolsConfigExists,
    IReadOnlyList<string> Problems)
{
    [System.Text.Json.Serialization.JsonIgnore]
    public WorkspaceDefaults? Defaults =>
        RootPath != null && ToolsPath != null && DefaultLane != null ? new WorkspaceDefaults(RootPath, ToolsPath, DefaultLane) : null;
}

public static class WorkspaceResolver
{
    /// <summary>Where octo-tools is (Start-OctoDevStackDaemon and Install-OctoDevStackDaemonService set it).</summary>
    public const string ToolsPathVariable = "OCTO_TOOLS_PATH";

    /// <summary>
    ///     The octo-tools checkout the daemon asks: <c>--octo-tools</c>, else $OCTO_TOOLS_PATH, else the octo-tools next to the
    ///     daemon's own checkout (where <c>Invoke-CloneMainRepos -devTools</c> puts both; a Claude Code worktree of
    ///     octo-devstack resolves to its main checkout first). Null when none of them holds octo-tools. This is the only
    ///     thing the daemon finds by itself: everything else about the machine comes from that octo-tools.
    /// </summary>
    public static string? LocateOctoTools(string? given, string daemonDirectory, Func<string, string?> environment)
    {
        if (!string.IsNullOrWhiteSpace(given))
        {
            return Path.GetFullPath(TemplateExpander.ExpandPath(given));
        }

        if (environment(ToolsPathVariable) is { Length: > 0 } fromEnvironment)
        {
            return Path.GetFullPath(TemplateExpander.ExpandPath(fromEnvironment));
        }

        return NextToCheckout(daemonDirectory);
    }

    /// <summary>The octo-tools folder next to the octo-devstack checkout that holds <paramref name="daemonDirectory"/>.</summary>
    internal static string? NextToCheckout(string daemonDirectory)
    {
        var directory = new DirectoryInfo(daemonDirectory);
        while (directory != null && !File.Exists(Path.Combine(directory.FullName, "Octo.DevStack.sln")))
        {
            directory = directory.Parent;
        }

        if (directory == null)
        {
            return null;
        }

        var checkout = directory.FullName;
        var marker = checkout.Replace('\\', '/').IndexOf("/.claude/worktrees/", StringComparison.Ordinal);
        if (marker >= 0)
        {
            checkout = checkout[..marker];
        }

        var parent = Path.GetDirectoryName(Path.TrimEndingDirectorySeparator(checkout));
        var tools = parent == null ? null : Path.Combine(parent, "octo-tools");
        return tools != null && File.Exists(Path.Combine(tools, "modules", "profile.ps1")) ? tools : null;
    }

    /// <summary>octo-tools was not found at all.</summary>
    public static WorkspaceInfo NotFound(string hint) => new("none", null, null, null, null, null, null, null, null,
        [$"octo-tools not found: clone it next to this octo-devstack checkout (Invoke-CloneMainRepos -devTools), set ${ToolsPathVariable}, or pass --octo-tools. {hint}".TrimEnd()]);

    /// <summary>Asks octo-tools for the workspace (Get-OctoWorkspace -Json).</summary>
    public static async Task<WorkspaceInfo> ResolveAsync(IPwshRunner runner, string toolsPath, TimeSpan timeout, CancellationToken cancellationToken)
    {
        PwshResult result;
        try
        {
            result = await runner.RunAsync(toolsPath, "Get-OctoWorkspace -Json", new PwshRunOptions { Timeout = timeout }, cancellationToken);
        }
        catch (Exception e) when (e is System.ComponentModel.Win32Exception or InvalidOperationException or IOException)
        {
            return Unanswered(toolsPath, $"pwsh could not be started ({e.Message}): install PowerShell 7.");
        }

        if (PwshRunner.ExtractOctoJson(result.Output, "Get-OctoWorkspace")?["data"] is JsonObject data)
        {
            return FromJson(data);
        }

        var tail = PwshRunner.Tail(result.Output, 3).Trim();
        if (result.TimedOut)
        {
            return Unanswered(toolsPath,
                $"octo-tools at {toolsPath} did not describe the workspace within {timeout.TotalSeconds:0} s (Get-OctoWorkspace with its profile: is it slow or waiting for input?). {tail}");
        }

        // Only a missing cmdlet means an octo-tools before AB#9377; a profile that throws or crashes is named as it is.
        if (result.Output.Contains("Get-OctoWorkspace", StringComparison.Ordinal) && result.Output.Contains("is not recognized", StringComparison.OrdinalIgnoreCase))
        {
            return Unanswered(toolsPath, $"octo-tools at {toolsPath} did not describe the workspace: Get-OctoWorkspace needs a newer octo-tools (git pull there). {tail}");
        }

        return Unanswered(toolsPath,
            $"octo-tools at {toolsPath} did not describe the workspace: Get-OctoWorkspace returned no document (exit code {result.ExitCode}). {tail}");
    }

    internal static WorkspaceInfo Unanswered(string toolsPath, string problem) =>
        new("unanswered", null, Path.TrimEndingDirectorySeparator(Path.GetFullPath(toolsPath)), null, null, null, null, null, null, [problem.TrimEnd()]);

    internal static WorkspaceInfo FromJson(JsonObject data) => new(
        "octo-tools",
        Str(data["rootPath"]),
        Str(data["toolsPath"]),
        Str(data["layout"]),
        Str(data["defaultLane"]),
        Str(data["defaultLanePath"]),
        Str(data["defaultLaneSource"]),
        Str(data["configDirectory"]),
        data["toolsConfigExists"] is JsonValue exists && exists.TryGetValue<bool>(out var b) ? b : null,
        (data["problems"] as JsonArray ?? []).Select(Str).OfType<string>().ToList());

    private static string? Str(JsonNode? node) => node is JsonValue value && value.TryGetValue<string>(out var s) && s.Length > 0 ? s : null;
}
