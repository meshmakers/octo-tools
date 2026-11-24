namespace Meshmakers.Octo.DevStack.Common;

/// <summary>Folders of the daemon's own state (not of the stack).</summary>
public sealed class DevStackPaths
{
    public DevStackPaths(string? stateDirectory = null)
    {
        StateDirectory = stateDirectory ?? DefaultStateDirectory();
        Directory.CreateDirectory(StateDirectory);
        Directory.CreateDirectory(BuildLogDirectory);
    }

    public string StateDirectory { get; }
    public string StateFile => Path.Combine(StateDirectory, "state.json");
    public string BuildLogDirectory => Path.Combine(StateDirectory, "builds");

    private static string DefaultStateDirectory()
    {
        var fromEnv = Environment.GetEnvironmentVariable("OCTO_DEVSTACK_STATE");
        if (!string.IsNullOrWhiteSpace(fromEnv))
        {
            return Path.GetFullPath(fromEnv);
        }

        var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        return Path.Combine(home, ".local", "state", "octo-devstack");
    }
}
