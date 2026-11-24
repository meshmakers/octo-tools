using System.Text.Json;
using System.Text.Json.Nodes;
using Meshmakers.Octo.DevStack.Configuration;

namespace Meshmakers.Octo.DevStack.Runtime;

/// <summary>
///     The generated files of a service in a non-default slot (<see cref="ServiceConfig.Files"/>): written into the slot's
///     folder in the state directory before the service starts, never into a repository. A frontend's runtime config is
///     the typical case - the app's own tracked config with the backend URLs of the slot.
/// </summary>
public static class ServiceFiles
{
    private static readonly JsonSerializerOptions Indented = new() { WriteIndented = true };

    private static readonly JsonDocumentOptions Lenient = new() { CommentHandling = JsonCommentHandling.Skip, AllowTrailingCommas = true };

    /// <summary>Writes every file of the service; returns their paths. <paramref name="repoPath"/> is the folder the service runs from.</summary>
    public static List<string> Write(DevStackConfig shifted, SlotInfo slot, string slotDirectory, string service, string repoPath)
    {
        var written = new List<string>();
        if (!shifted.Services.TryGetValue(service, out var config) || config.Files.Count == 0)
        {
            return written;
        }

        var directory = SlotDeriver.FilesDirectory(slotDirectory, service);
        foreach (var file in config.Files)
        {
            var target = Path.GetFullPath(Path.Combine(directory, file.Path));
            if (!target.StartsWith(Path.GetFullPath(directory) + Path.DirectorySeparatorChar, StringComparison.Ordinal))
            {
                throw new InvalidOperationException($"File '{file.Path}' of service '{service}' leaves its folder {directory}.");
            }

            var content = Render(shifted, slot, slotDirectory, service, repoPath, file);
            Directory.CreateDirectory(Path.GetDirectoryName(target)!);
            var temp = target + ".tmp";
            File.WriteAllText(temp, content);
            Common.SharedFile.Replace(temp, target);
            written.Add(target);
        }

        return written;
    }

    /// <summary>The content of one generated file: the repository's JSON file with the set keys replaced (pure but for reading the base file).</summary>
    public static string Render(DevStackConfig shifted, SlotInfo slot, string slotDirectory, string service, string repoPath, ServiceFile file)
    {
        var json = new JsonObject();
        if (file.From != null)
        {
            var source = Path.GetFullPath(Path.Combine(repoPath, file.From));
            if (!File.Exists(source))
            {
                throw new InvalidOperationException($"Service '{service}': the base file {source} of its generated file '{file.Path}' does not exist.");
            }

            try
            {
                json = JsonNode.Parse(File.ReadAllText(source), null, Lenient) as JsonObject
                       ?? throw new InvalidOperationException($"Service '{service}': {source} is not a JSON object.");
            }
            catch (JsonException e)
            {
                throw new InvalidOperationException($"Service '{service}': {source} is not valid JSON ({e.Message}).", e);
            }
        }

        foreach (var (key, value) in file.Set)
        {
            try
            {
                json[key] = SlotDeriver.Render(value, shifted, slot, slotDirectory, service);
            }
            catch (SlotDeriver.NotApplicableException)
            {
                // The value names a service this configuration does not have (an adapter the developer did not define):
                // the key keeps what the repository's file says.
            }
        }

        return json.ToJsonString(Indented) + "\n";
    }
}
