namespace Meshmakers.Octo.DevStack.Configuration;

/// <summary>
///     A stack slot: one of several OctoMesh backend stacks on this machine. The default slot (index 0) runs on the
///     configured ports with today's data names; every other slot shifts its ports by <see cref="PortOffset"/> and isolates
///     its data with <see cref="Prefix"/>.
/// </summary>
public sealed record SlotInfo(string Name, int Index, int PortOffset, string Prefix)
{
    public const string DefaultName = "default";

    public static readonly SlotInfo Default = new(DefaultName, 0, 0, "");

    public bool IsDefault => Index == 0;
}
