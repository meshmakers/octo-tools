using System.Collections;
using System.ComponentModel;
using System.Reflection;
using System.Text.Json;
using System.Text.Json.Nodes;
using Meshmakers.Octo.DevStack.Tools;
using ModelContextProtocol;
using ModelContextProtocol.Server;

namespace Meshmakers.Octo.DevStack.Ui;

/// <summary>A parameter of a read-only tool as GET /api/tools lists it.</summary>
public sealed record BridgedParameter(string Name, string Type, bool Required, object? Default, string? Description);

/// <summary>A read-only tool reachable as GET /api/tools/{name}.</summary>
public sealed record BridgedTool(string Name, string Url, string? Description, IReadOnlyList<BridgedParameter> Parameters);

/// <summary>GET /api/tools: the read-only tools, and the changing ones that stay MCP-only.</summary>
public sealed record BridgedToolList(IReadOnlyList<BridgedTool> Tools, IReadOnlyList<string> McpOnly, string Note);

/// <summary>
///     Every read-only MCP tool is also a GET endpoint: /api/tools/{name}?arg=value runs the tool's method with the same
///     arguments and returns its result as JSON. Changing tools stay MCP-only: the HTTP API has no authentication, and a lease
///     owner must be a session, not whatever page a browser runs. Together with the tools of <see cref="StatusPageTools"/>
///     (every read endpoint of the status page is a tool) the API and MCP read the same things.
/// </summary>
public static class ToolBridge
{
    internal sealed record ToolMethod(string Name, MethodInfo Method, bool ReadOnly);

    private static readonly JsonSerializerOptions Json = new(JsonSerializerDefaults.Web);

    /// <summary>Every [McpServerTool] method of the daemon - what WithToolsFromAssembly registers.</summary>
    internal static IReadOnlyList<ToolMethod> All { get; } = typeof(ToolBridge).Assembly.GetTypes()
        .Where(t => t.GetCustomAttribute<McpServerToolTypeAttribute>() != null)
        .SelectMany(t => t.GetMethods(BindingFlags.Public | BindingFlags.Instance | BindingFlags.Static | BindingFlags.DeclaredOnly))
        .Select(m => (Method: m, Attribute: m.GetCustomAttribute<McpServerToolAttribute>()))
        .Where(x => x.Attribute != null)
        .Select(x => new ToolMethod(x.Attribute!.Name ?? x.Method.Name, x.Method, x.Attribute.ReadOnly))
        .OrderBy(x => x.Name, StringComparer.Ordinal)
        .ToList();

    public static void MapToolBridge(this WebApplication app)
    {
        app.MapGet("/api/tools", () => Results.Ok(List()));

        app.MapGet("/api/tools/{name}", async (string name, HttpContext context) =>
        {
            // A read-only call may still be expensive (build_plan runs the cmdlets with -WhatIf): a page of another site must not
            // trigger it through an <img> or a link. Browsers name the origin of the request in Sec-Fetch-Site; curl sends none.
            if (context.Request.Headers["Sec-Fetch-Site"].ToString() is { Length: > 0 } site && site is not ("same-origin" or "none"))
            {
                return Results.Json(new { error = "Cross-site requests are refused." }, statusCode: StatusCodes.Status403Forbidden);
            }

            var tool = All.FirstOrDefault(t => t.Name == name);
            if (tool == null)
            {
                return Results.NotFound(new { error = $"There is no tool '{name}'. GET /api/tools lists them." });
            }

            if (!tool.ReadOnly)
            {
                return Results.Json(new { error = $"'{name}' changes state and is MCP-only (lease, owner); call it through the MCP endpoint /mcp." },
                    statusCode: StatusCodes.Status405MethodNotAllowed);
            }

            object?[] arguments;
            try
            {
                arguments = Bind(tool, context.Request.Query.ToDictionary(q => q.Key, q => q.Value.Select(v => v ?? "").ToArray()), context.RequestAborted);
            }
            catch (Exception e) when (e is ArgumentException or JsonException or FormatException)
            {
                return Results.BadRequest(new
                {
                    error = ArgumentErrors.Describe(name, e.Message, context.Request.Query.Keys.ToList(), Parameters(tool).Select(p => p.Name).ToList())
                });
            }

            try
            {
                return Results.Json(await InvokeAsync(tool, context.RequestServices, arguments));
            }
            catch (McpException e)
            {
                return Results.BadRequest(new { error = e.Message });
            }
        });
    }

    internal static BridgedToolList List() => new(
        All.Where(t => t.ReadOnly).Select(t => new BridgedTool(t.Name, $"/api/tools/{t.Name}", t.Method.GetCustomAttribute<DescriptionAttribute>()?.Description,
            Parameters(t))).ToList(),
        All.Where(t => !t.ReadOnly).Select(t => t.Name).ToList(),
        "GET /api/tools/{name}?arg=value runs a read-only tool with the arguments of its MCP call (a list: repeat the argument, or " +
        "comma-separated, or a JSON array; a map or object: JSON). Changing tools are MCP-only.");

    internal static IReadOnlyList<BridgedParameter> Parameters(ToolMethod tool) => tool.Method.GetParameters()
        .Where(p => p.ParameterType != typeof(CancellationToken))
        .Select(p => new BridgedParameter(p.Name!, TypeName(p.ParameterType), !p.HasDefaultValue, p.HasDefaultValue ? p.DefaultValue : null,
            p.GetCustomAttribute<DescriptionAttribute>()?.Description))
        .ToList();

    /// <summary>The method's arguments from the query: unknown names and missing required ones are an ArgumentException.</summary>
    internal static object?[] Bind(ToolMethod tool, IReadOnlyDictionary<string, string[]> query, CancellationToken cancellationToken)
    {
        var parameters = tool.Method.GetParameters();
        var unknown = query.Keys.Where(k => !parameters.Any(p => p.ParameterType != typeof(CancellationToken) && p.Name == k)).ToList();
        if (unknown.Count > 0)
        {
            throw new ArgumentException($"unknown argument(s) {string.Join(", ", unknown)}.");
        }

        return parameters.Select(p =>
        {
            if (p.ParameterType == typeof(CancellationToken))
            {
                return cancellationToken;
            }

            if (!query.TryGetValue(p.Name!, out var values))
            {
                return p.HasDefaultValue ? p.DefaultValue : throw new ArgumentException($"'{p.Name}' is required.");
            }

            return Convert(p.Name!, p.ParameterType, values);
        }).ToArray();
    }

    private static object? Convert(string name, Type type, string[] values)
    {
        var target = Nullable.GetUnderlyingType(type) ?? type;
        if (target == typeof(string))
        {
            return values.LastOrDefault();
        }

        var raw = values.LastOrDefault() ?? "";
        if (IsList(target))
        {
            var items = values.Length == 1 && raw.TrimStart().StartsWith('[')
                ? JsonNode.Parse(raw)
                : new JsonArray((values.Length == 1 ? raw.Split(',', StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries) : values)
                    .Select(v => (JsonNode?)JsonValue.Create(v)).ToArray());
            return items.Deserialize(type, Json);
        }

        try
        {
            return JsonSerializer.Deserialize(raw, type, Json);
        }
        catch (JsonException)
        {
            throw new ArgumentException($"'{name}' must be a {TypeName(type)}, not '{raw}'.");
        }
    }

    private static bool IsList(Type type) =>
        type != typeof(string) && typeof(IEnumerable).IsAssignableFrom(type) && !type.IsAssignableTo(typeof(IDictionary)) &&
        !(type.IsGenericType && type.GetGenericArguments().Length == 2);

    internal static async Task<object?> InvokeAsync(ToolMethod tool, IServiceProvider services, object?[] arguments)
    {
        var instance = tool.Method.IsStatic ? null : ActivatorUtilities.CreateInstance(services, tool.Method.DeclaringType!);
        object? result;
        try
        {
            result = tool.Method.Invoke(instance, arguments);
            if (result is Task task)
            {
                await task;
                result = task.GetType().IsGenericType ? task.GetType().GetProperty("Result")!.GetValue(task) : null;
            }
        }
        catch (TargetInvocationException e) when (e.InnerException != null)
        {
            System.Runtime.ExceptionServices.ExceptionDispatchInfo.Capture(e.InnerException).Throw();
            throw;
        }
        finally
        {
            (instance as IDisposable)?.Dispose();
        }

        return result;
    }

    private static string TypeName(Type type)
    {
        var target = Nullable.GetUnderlyingType(type) ?? type;
        if (target == typeof(string)) return "string";
        if (target == typeof(bool)) return "boolean";
        if (target == typeof(int) || target == typeof(long)) return "integer";
        if (target == typeof(double)) return "number";
        if (IsList(target)) return "list";
        // A map comes as a JSON object (Convert deserializes the raw value); anything else would need a converter here.
        if (target.IsAssignableTo(typeof(IDictionary)) || (target.IsGenericType && target.GetGenericTypeDefinition() == typeof(Dictionary<,>))) return "map";
        return "object";
    }
}
