using Meshmakers.Octo.DevStack.Common;

namespace Meshmakers.Octo.DevStack.Runtime;

/// <summary>
///     Status as it leaves the daemon (stack_status, start/stop results, /api/overview): command lines and arguments with
///     secret values and URI credentials masked. Internally (profile matching, capture) the raw values are used.
/// </summary>
public static class StatusMask
{
    public static StackStatus Masked(this StackStatus status) => status with
    {
        Services = status.Services.Select(s => s with { Args = SecretMask.MaskArgs(s.Args) }).ToList(),
        // "with": the scan's warning (external processes unknown, AB#9556) stays in the answer.
        External = status.External with
        {
            Services = status.External.Services.Select(s => s with { Command = SecretMask.MaskCommandLine(s.Command) }).ToList(),
            Groups = status.External.Groups.Select(g => g with
            {
                Origin = g.Origin with
                {
                    LauncherCommand = g.Origin.LauncherCommand == null ? null : SecretMask.MaskCommandLine(g.Origin.LauncherCommand)
                }
            }).ToList()
        }
    };

    public static StartResult Masked(this StartResult result) => result with { Status = result.Status.Masked() };

    public static StopResult Masked(this StopResult result) => result with { Status = result.Status.Masked() };
}
