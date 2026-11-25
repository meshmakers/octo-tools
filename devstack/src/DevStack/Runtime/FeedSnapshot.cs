using System.Text.Json.Nodes;

namespace Meshmakers.Octo.DevStack.Runtime;

/// <summary>
///     The notes lane_create, lane_add_repo and lane_build make of octo-tools' feedSnapshot (Get-OctoEnvironmentFeedSnapshotReport,
///     AB#9808): libraries outside the lane whose base-lane packages were built from a commit behind their upstream - the cause of
///     CS0246/CS1061 in the lane's consumers - with the fix, and a check that could not be made, said as such instead of an empty list.
/// </summary>
public static class FeedSnapshot
{
    /// <summary>The notes for one feedSnapshot object; empty when it is missing (an older octo-tools) or has nothing to say.</summary>
    public static List<string> Notes(JsonNode? snapshot, string lane)
    {
        var notes = new List<string>();
        if (snapshot is not JsonObject report)
        {
            return notes;
        }

        var stale = (report["staleProducers"] as JsonArray ?? []).OfType<JsonObject>().ToList();
        if (stale.Count > 0)
        {
            var rows = stale.Select(s =>
            {
                var built = Text(s["builtFrom"]);
                var from = built is { Length: > 0 } ? $"built from {built[..Math.Min(8, built.Length)]}, " : "";
                var consumers = (s["consumedBy"] as JsonArray ?? []).Select(Text).Where(c => c != null);
                return $"{Text(s["repo"])} ({from}{Text(s["behind"])} commit(s) behind {Text(s["upstream"])}, consumed by {string.Join(", ", consumers)})";
            });
            var fixes = stale.Select(s => $"lane_add_repo(owner, lane=\"{lane}\", repo=\"{Text(s["repo"])}\", role=\"consumer\")");
            notes.Add($"Stale base-lane packages: {string.Join("; ", rows)}. The lane's consumers may fail with CS0246/CS1061 against them. " +
                      $"Fix: {string.Join(", ", fixes)}, then lane_build(owner, lane=\"{lane}\").");
        }

        if (report["checked"] is JsonValue checkedValue && checkedValue.TryGetValue<bool>(out var ok) && !ok)
        {
            var errors = (report["errors"] as JsonArray ?? []).Select(Text).Where(e => !string.IsNullOrWhiteSpace(e)).ToList();
            notes.Add($"The stale-package check failed{(errors.Count > 0 ? $": {string.Join("; ", errors)}" : "")}. " +
                      "Stale base-lane packages are not ruled out (staleProducers is incomplete).");
        }

        return notes;
    }

    private static string? Text(JsonNode? node) => node is JsonValue value ? value.ToString() : null;
}
