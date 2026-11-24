using Meshmakers.Octo.DevStack.Leasing;
using ModelContextProtocol;

namespace Meshmakers.Octo.DevStack.Tools;

/// <summary>Turns expected failures into tool errors whose message reaches the agent.</summary>
internal static class ToolGuard
{
    public static async Task<T> Run<T>(Func<Task<T>> action)
    {
        try
        {
            return await action();
        }
        catch (Exception e) when (e is InvalidOperationException or ArgumentException or LeaseHeldException or IOException
                                      or UnauthorizedAccessException)
        {
            throw new McpException(e.Message, e);
        }
    }

    public static T Run<T>(Func<T> action)
    {
        try
        {
            return action();
        }
        catch (Exception e) when (e is InvalidOperationException or ArgumentException or LeaseHeldException or IOException
                                      or UnauthorizedAccessException)
        {
            throw new McpException(e.Message, e);
        }
    }

    public static TimeSpan Timeout(int seconds) => TimeSpan.FromSeconds(Math.Clamp(seconds, 1, 900));
}
