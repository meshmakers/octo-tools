using System.Text.Json;
using System.Text.Json.Nodes;
using Meshmakers.Octo.DevStack.Builds;
using Meshmakers.Octo.DevStack.Common;

namespace Meshmakers.Octo.DevStack.Runtime;

/// <summary>
///     A process that holds files below a folder, as octo-tools Get-OctoProcessesUnderFolder finds it (working directory on
///     macOS/Linux, entry assembly, on Windows the modules of dotnet processes): pid, name, why, start time - never a command line.
/// </summary>
public sealed record FolderProcess(int Pid, string Name, string Reason, string Folder)
{
    public DateTimeOffset? StartedAt { get; init; }

    public override string ToString() =>
        $"pid {Pid} {Name}{(StartedAt is { } started ? $", started {started.ToLocalTime():yyyy-MM-dd HH:mm:ss}" : "")} ({Reason})";
}

/// <summary>A service the daemon started (in any stack) whose process tree holds files below the lane.</summary>
public sealed record OwnFolderProcess(FolderProcess Process, string Slot, string Service, string? StartedBy);

/// <summary>The processes below a lane, sorted by who they belong to.</summary>
/// <param name="LaneStack">Services of the lane's own stack (lane_remove stops them).</param>
/// <param name="OtherStacks">Services of another stack that run from the lane (e.g. a lane's build of one service in the shared stack).</param>
/// <param name="Foreign">Processes below the lane folder the daemon did not start: a reused MSBuild node, a shell, an IDE.</param>
/// <param name="ForeignInPlace">Processes the daemon did not start below in-place worktrees only (they stay: Remove-OctoEnvironment only unregisters them).</param>
public sealed record LaneProcessCheck(
    IReadOnlyList<OwnFolderProcess> LaneStack,
    IReadOnlyList<OwnFolderProcess> OtherStacks,
    IReadOnlyList<FolderProcess> Foreign,
    IReadOnlyList<FolderProcess> ForeignInPlace)
{
    public static readonly LaneProcessCheck Empty = new([], [], [], []);
}

/// <summary>
///     Which processes hold files below a lane before lane_remove deletes it. The matching rule is octo-tools'
///     (Get-OctoProcessesUnderFolder of Invoke-KillDotnet.psm1, list-only), run through the daemon's pwsh runner; the daemon
///     only sorts the answer into its own services and the rest.
/// </summary>
public static class LaneProcesses
{
    public const string Cmdlet = "Get-OctoProcessesUnderFolder";

    /// <summary>
    ///     One pwsh run over every folder; the pwsh itself is left out. The marker line holds { folder, pid, name, reason } per
    ///     process. Windows: PowerShell's Process.CommandLine asks WMI once per process (about a second each; the cmdlet reads it
    ///     for every process, so ~600 processes took over ten minutes), so the session answers it from one Win32_Process query
    ///     made before (about 1.5 s). The command lines stay inside the pwsh process; the matching rule is octo-tools'.
    /// </summary>
    internal static string Script(IReadOnlyList<string> folders) =>
        $$"""
          if ($IsWindows) {
              $global:__octoCommandLines = @{}
              foreach ($__c in @(Get-CimInstance -ClassName Win32_Process -Property ProcessId, CommandLine -ErrorAction SilentlyContinue)) {
                  $global:__octoCommandLines[[int]$__c.ProcessId] = $__c.CommandLine
              }
              Update-TypeData -TypeName System.Diagnostics.Process -MemberName CommandLine -MemberType ScriptProperty -Force -Value {
                  if ($global:__octoCommandLines.ContainsKey($this.Id)) { $global:__octoCommandLines[$this.Id] }
                  else { (Get-CimInstance -ClassName Win32_Process -Filter "ProcessId = $($this.Id)" -ErrorAction SilentlyContinue).CommandLine }
              }
          }
          $__r = @(foreach ($__f in @({{string.Join(", ", folders.Select(PwshRunner.Quote))}})) {
              foreach ($__p in @({{Cmdlet}} -path $__f)) {
                  if ($__p.pid -ne $PID) { [ordered]@{ folder = $__f; pid = [int]$__p.pid; name = [string]$__p.name; reason = [string]$__p.reason } }
              }
          })
          '{{PwshRunner.Marker}}' + (ConvertTo-Json -InputObject @($__r) -Compress -Depth 3)
          """;

    /// <summary>The processes of the marker line, with their start times; throws when the run gave no readable answer.</summary>
    internal static List<FolderProcess> Parse(PwshResult result, Func<int, DateTimeOffset?>? startTime = null)
    {
        JsonNode? marker;
        try
        {
            marker = result.ExitCode == 0 && !result.TimedOut ? PwshRunner.ExtractMarker(result.Output) : null;
        }
        catch (JsonException e)
        {
            throw new InvalidOperationException($"{Cmdlet} printed no readable result ({e.Message})");
        }

        if (marker is not JsonArray list)
        {
            var last = PwshRunner.Tail(result.Output, 1).Trim();
            throw new InvalidOperationException($"{Cmdlet} gave no result (exit {result.ExitCode}{(result.TimedOut ? ", timed out" : "")}){(last.Length > 0 ? ": " + SecretMask.MaskValue(last) : "")}");
        }

        startTime ??= ProcessTree.StartTime;
        return list.OfType<JsonObject>()
            .Select(o => (Pid: (int?)BuildPlanner.Num(o["pid"]) ?? 0, Object: o))
            .Where(p => p.Pid > 0)
            .Select(p => new FolderProcess(p.Pid, BuildPlanner.Str(p.Object["name"]) ?? "?", BuildPlanner.Str(p.Object["reason"]) ?? "?", BuildPlanner.Str(p.Object["folder"]) ?? "")
                { StartedAt = startTime(p.Pid) })
            .ToList();
    }

    /// <summary>Every process of the daemon's services (the recorded pid and all its descendants: on Windows the recorded one is the cmd.exe wrapper).</summary>
    internal static Dictionary<int, (string Slot, string Service, string? StartedBy)> OwnProcesses(
        IEnumerable<(string Slot, string Service, int Pid, string? StartedBy)> services, IEnumerable<(int Pid, int ParentPid)> links)
    {
        var all = links.ToList();
        var own = new Dictionary<int, (string, string, string?)>();
        foreach (var (slot, service, pid, startedBy) in services.Where(s => s.Pid > 0))
        {
            foreach (var p in ProcessTree.DescendantsOf(pid, all))
            {
                own.TryAdd(p, (slot, service, startedBy));
            }
        }

        return own;
    }

    /// <summary>Sorts what was found: a process below the lane folder counts there, one only below an in-place worktree counts as in place.</summary>
    internal static LaneProcessCheck Classify(IReadOnlyList<FolderProcess> found, string laneFolder, string laneSlot,
        IReadOnlyDictionary<int, (string Slot, string Service, string? StartedBy)> own)
    {
        var byPid = found.GroupBy(p => p.Pid)
            .Select(g => g.FirstOrDefault(p => PathScope.SamePath(p.Folder, laneFolder)) ?? g.First())
            .OrderBy(p => p.Pid).ToList();
        var laneStack = new List<OwnFolderProcess>();
        var otherStacks = new List<OwnFolderProcess>();
        var foreign = new List<FolderProcess>();
        var inPlace = new List<FolderProcess>();
        foreach (var process in byPid)
        {
            var inLane = process.Folder.Length > 0 && PathScope.SamePath(process.Folder, laneFolder);
            if (own.TryGetValue(process.Pid, out var service))
            {
                if (service.Slot == laneSlot)
                {
                    laneStack.Add(new OwnFolderProcess(process, service.Slot, service.Service, service.StartedBy));
                }
                else if (inLane)
                {
                    otherStacks.Add(new OwnFolderProcess(process, service.Slot, service.Service, service.StartedBy));
                }

                // A service of another stack below an in-place worktree only: the worktree stays, so does the service.
                continue;
            }

            (inLane ? foreign : inPlace).Add(process);
        }

        // One service may have several processes below the lane (the cmd.exe wrapper and its dotnet child): one line each service.
        return new LaneProcessCheck(laneStack, otherStacks.GroupBy(o => (o.Slot, o.Service)).Select(g => g.First()).ToList(), foreign, inPlace);
    }

    private static string StackLabel(string slot) => slot == Configuration.SlotInfo.DefaultName ? "the shared stack" : $"stack '{slot}'";

    /// <summary>
    ///     The refusal of lane_remove: the processes that hold files below the lane, what to do about each, and whether something
    ///     was changed already (null: nothing blocks).
    /// </summary>
    /// <param name="afterStop">The check after the lane stack was stopped: its own services count as blockers then (they did not end).</param>
    internal static string? Refusal(string lane, string laneFolder, LaneProcessCheck check, bool afterStop)
    {
        var lines = new List<string>();
        foreach (var own in check.OtherStacks)
        {
            lines.Add($"- service {own.Service} of {StackLabel(own.Slot)} ({own.Process}{(own.StartedBy != null ? $", started by {own.StartedBy}" : "")}) runs from the lane: " +
                      $"stop it there (service_stop with that stack's lease) and start it again from the base lane");
        }

        if (afterStop)
        {
            lines.AddRange(check.LaneStack.Select(own => $"- {own.Process}: a process of the lane stack's service {own.Service} that did not end with the stack"));
        }

        lines.AddRange(check.Foreign.Select(p => $"- {p}"));
        if (lines.Count == 0)
        {
            return null;
        }

        var hints = new List<string>();
        if (check.Foreign.Any(p => p.Name.StartsWith("dotnet", StringComparison.OrdinalIgnoreCase)))
        {
            hints.Add("a dotnet process with a module below the lane is usually an MSBuild node a plain `dotnet build` left running: `dotnet build-server shutdown` ends it");
        }

        if (check.Foreign.Any(p => !p.Name.StartsWith("dotnet", StringComparison.OrdinalIgnoreCase)))
        {
            hints.Add("close the shells, IDEs or sessions that work in the folder");
        }

        return $"Lane '{lane}' was not removed: {lines.Count} process(es) the removal would collide with hold files below {laneFolder} " +
               $"({(afterStop ? "the lane stack is stopped now, nothing else was changed" : "nothing was changed, the lane stack still runs")}):\n" +
               string.Join("\n", lines) + "\n" +
               (hints.Count > 0 ? $"Stop them ({string.Join("; ", hints)}), then call lane_remove again." : "Stop them, then call lane_remove again.");
    }
}
