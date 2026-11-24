using System.Text.Json;
using ModelContextProtocol;
using ModelContextProtocol.Protocol;
using ModelContextProtocol.Server;

namespace Meshmakers.Octo.DevStack.Tools;

/// <summary>
///     Tells the client why its arguments did not bind. The SDK answers an exception other than <see cref="McpException"/>
///     with "An error occurred invoking '&lt;tool&gt;'." only; argument binding (Microsoft.Extensions.AI) throws an
///     ArgumentException for a missing required parameter and a JsonException for a value of the wrong type, before the tool
///     body (and its <see cref="ToolGuard"/>) runs. This call-tool filter turns both into an McpException that names the
///     problem, the unknown argument names and the tool's parameters.
/// </summary>
internal static class ArgumentErrors
{
    public static McpRequestHandler<CallToolRequestParams, CallToolResult> Filter(McpRequestHandler<CallToolRequestParams, CallToolResult> next) =>
        async (context, cancellationToken) =>
        {
            try
            {
                return await next(context, cancellationToken);
            }
            catch (Exception e) when (e is ArgumentException or JsonException)
            {
                var known = (context.MatchedPrimitive as McpServerTool)?.ProtocolTool.InputSchema is { ValueKind: JsonValueKind.Object } schema &&
                            schema.TryGetProperty("properties", out var properties) && properties.ValueKind == JsonValueKind.Object
                    ? properties.EnumerateObject().Select(p => p.Name).ToList()
                    : null;
                throw new McpException(Describe(context.Params?.Name ?? "?", e.Message, context.Params?.Arguments?.Keys.ToList() ?? [], known), e);
            }
        };

    /// <summary>The message the client gets: the binding error, unknown argument names and the parameters of the tool.</summary>
    internal static string Describe(string tool, string error, IReadOnlyCollection<string> provided, IReadOnlyCollection<string>? known)
    {
        var text = $"Invalid arguments for {tool}: {error}";
        if (known == null)
        {
            return text;
        }

        var unknown = provided.Where(p => !known.Contains(p, StringComparer.Ordinal)).ToList();
        if (unknown.Count > 0)
        {
            text += $" Unknown argument(s): {string.Join(", ", unknown)}.";
        }

        return text + $" Parameters of {tool}: {string.Join(", ", known)}.";
    }
}
