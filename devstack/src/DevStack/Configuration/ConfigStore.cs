using System.Reflection;
using YamlDotNet.Serialization;
using YamlDotNet.Serialization.NamingConventions;

namespace Meshmakers.Octo.DevStack.Configuration;

/// <summary>Loads and persists devstack.yaml. Every read returns a fresh copy, so a running start keeps its snapshot.</summary>
public sealed class ConfigStore
{
    private readonly Lock _lock = new();

    private static readonly IDeserializer Deserializer = new DeserializerBuilder()
        .WithNamingConvention(CamelCaseNamingConvention.Instance)
        .Build();

    private static readonly ISerializer Serializer = new SerializerBuilder()
        .WithNamingConvention(CamelCaseNamingConvention.Instance)
        .ConfigureDefaultValuesHandling(DefaultValuesHandling.OmitEmptyCollections | DefaultValuesHandling.OmitNull)
        .WithIndentedSequences()
        .Build();

    public ConfigStore(string path)
    {
        ConfigPath = path;
    }

    public string ConfigPath { get; }

    /// <summary>
    ///     The workspace's values for what the file leaves out (rootPath, defaultCheckout) and the octo-tools the daemon asked;
    ///     every config this store loads or updates carries them. Null: no workspace, the folders are unknown.
    /// </summary>
    public WorkspaceDefaults? Workspace { get; set; }

    /// <summary>The workspace as resolved at the daemon's start (shown by config_get); setting it sets <see cref="Workspace"/>.</summary>
    public WorkspaceInfo? WorkspaceInfo
    {
        get;
        set
        {
            field = value;
            Workspace = value?.Defaults;
        }
    }

    /// <summary>The file name of the shared daemon's config in the octo-tools config folder.</summary>
    public const string FileName = "devstack.yaml";

    /// <summary>
    ///     devstack.yaml in the octo-tools config folder that Get-OctoWorkspace names (installations.json lies there, AB#9377);
    ///     null when octo-tools did not describe the workspace. The daemon has no rule of its own for that folder.
    /// </summary>
    public static string? PathIn(WorkspaceInfo workspace) =>
        workspace.ConfigDirectory is { Length: > 0 } folder ? Path.Combine(folder, FileName) : null;

    /// <summary>Where a daemon before AB#9377 kept the file of this name (devstack.yaml, devstack.dev.yaml).</summary>
    public static string LegacyPath(string fileName) => LegacyPath(fileName, Home);

    internal static string LegacyPath(string fileName, string home) => Path.Combine(home, ".config", "octo-devstack", fileName);

    private static string Home => Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);

    /// <summary>Writes the embedded default when no file exists yet. Returns true when it did.</summary>
    public bool EnsureExists()
    {
        lock (_lock)
        {
            if (File.Exists(ConfigPath))
            {
                return false;
            }

            Directory.CreateDirectory(Path.GetDirectoryName(ConfigPath)!);
            File.WriteAllText(ConfigPath, UserDefaultYaml());
            return true;
        }
    }

    /// <summary>
    ///     Takes over the file of a daemon before AB#9377 when this store's file does not exist yet: the content is copied
    ///     without octoToolsPath (not read any more: the daemon uses the octo-tools it asked) and without the rootPath /
    ///     defaultCheckout lines that only repeat what the workspace says (they would pin this machine's folders into the
    ///     file). The old file stays as it is - a running older daemon still reads it - and is not read again. Returns what
    ///     happened, or null when there was nothing to take over.
    /// </summary>
    public string? TakeOver(string legacyPath, WorkspaceDefaults? workspace)
    {
        lock (_lock)
        {
            if (File.Exists(ConfigPath) || !File.Exists(legacyPath))
            {
                return null;
            }

            var text = Common.SharedFile.ReadAllText(legacyPath);
            var settings = Parse(text, legacyPath);
            var removed = new List<string>();
            if (settings.OctoToolsPathSetting != null)
            {
                removed.Add("octoToolsPath");
            }

            if (workspace != null)
            {
                var resolved = new DevStackConfig { Workspace = workspace };
                if (settings.RootPathSetting != null && Common.PathScope.SamePath(ServicePlanner.RootPath(settings), ServicePlanner.RootPath(resolved)))
                {
                    removed.Add("rootPath");
                }

                // The root the new file runs with: its own rootPath when that line stays, else the workspace's. Both the
                // file's defaultCheckout and the lane it would inherit without the line are resolved below it.
                var keptRoot = settings.RootPathSetting == null || removed.Contains("rootPath")
                    ? ServicePlanner.RootPath(resolved)
                    : ServicePlanner.RootPath(settings);
                if (settings.DefaultCheckoutSetting is { } ownCheckout && SameCheckout(ownCheckout, resolved.DefaultCheckout, keptRoot))
                {
                    removed.Add("defaultCheckout");
                }
            }

            var content = WithoutKeys(text, removed);
            var note = removed.Count > 0 ? $"; {string.Join(", ", removed)} removed (octo-tools describes the workspace)" : "";
            try
            {
                Parse(content, legacyPath);
            }
            catch (InvalidOperationException)
            {
                // The keys could not be cut out cleanly: the file as it was (its octoToolsPath is not read anyway).
                content = text;
                note = removed.Count > 0 ? $"; {string.Join(", ", removed)} could not be removed cleanly and are left in - delete them by hand (octo-tools describes the workspace)" : "";
            }

            var header = $"# Taken over from {legacyPath} on {DateTime.Now:yyyy-MM-dd}{note}.";
            Directory.CreateDirectory(Path.GetDirectoryName(ConfigPath)!);
            // Whole or not at all: a half-written file would exist and stop every later take-over.
            var temp = ConfigPath + ".tmp";
            File.WriteAllText(temp, header + "\n" + content);
            Common.SharedFile.Replace(temp, ConfigPath);
            return $"{header[2..]} The old file is no longer read and can be deleted.";
        }
    }

    /// <summary>
    ///     The text without the top-level <paramref name="keys"/>: the key line and its value's continuation lines (indented or
    ///     blank, e.g. a folded block <c>key: &gt;-</c> with the value on the next line). Comments and other keys stay.
    /// </summary>
    internal static string WithoutKeys(string text, IReadOnlyCollection<string> keys)
    {
        var kept = new List<string>();
        var inRemovedNode = false;
        foreach (var line in text.Split('\n'))
        {
            if (keys.Any(key => System.Text.RegularExpressions.Regex.IsMatch(line, $@"^{key}:(\s|$)")))
            {
                inRemovedNode = true;
                continue;
            }

            if (inRemovedNode && (line.TrimEnd('\r').Length == 0 || line.StartsWith(' ') || line.StartsWith('\t')))
            {
                continue;
            }

            inRemovedNode = false;
            kept.Add(line);
        }

        return string.Join('\n', kept);
    }

    private static bool SameCheckout(string ownCheckout, string inheritedCheckout, string keptRoot)
    {
        try
        {
            return Common.PathScope.SamePath(ServicePlanner.ResolveFolder(ownCheckout, keptRoot, null, "checkout"),
                ServicePlanner.ResolveFolder(inheritedCheckout, keptRoot, null, "checkout"));
        }
        catch (InvalidOperationException)
        {
            return false; // one of them does not exist: keep the line, the config problems name it
        }
    }

    private const string BuiltInStart = "# >>> built-in slotDerivations";
    private const string BuiltInEnd = "# <<< built-in slotDerivations";

    /// <summary>
    ///     The default as written into a new devstack.yaml: without the built-in slot derivation table, so later versions of
    ///     the table reach the developer (a copy in the file would freeze it). Rows in the file replace built-in rows by id.
    /// </summary>
    public static string UserDefaultYaml()
    {
        var yaml = ReadDefaultYaml();
        var start = yaml.IndexOf(BuiltInStart, StringComparison.Ordinal);
        var end = yaml.IndexOf(BuiltInEnd, StringComparison.Ordinal);
        if (start < 0 || end < start)
        {
            return yaml;
        }

        var lineEnd = yaml.IndexOf('\n', end);
        return yaml[..start] +
               "# slotDerivations: built in (octo-devstack --print-default-config shows the table). Rows added here replace\n" +
               "# built-in rows of the same id; 'disabled: true' removes one.\n" +
               (lineEnd < 0 ? "" : yaml[(lineEnd + 1)..]);
    }

    private static readonly Lazy<DevStackConfig> BuiltInConfig = new(() =>
    {
        var config = Deserializer.Deserialize<DevStackConfig?>(ReadDefaultYaml()) ?? new DevStackConfig();
        config.EffectiveSlotDerivations = SlotDeriver.MergeTables(config.SlotDerivations, null);
        return config;
    });

    /// <summary>The embedded default, parsed once without validation (built-in slot table, built-in service flags).</summary>
    public static DevStackConfig BuiltIn => BuiltInConfig.Value;

    /// <summary>The startAfter of the built-in service of that name (empty for a service the default does not have).</summary>
    internal static IReadOnlyList<string> BuiltInStartAfter(string service) =>
        BuiltIn.Services.TryGetValue(service, out var builtIn) ? builtIn.StartAfter : [];

    public static string ReadDefaultYaml()
    {
        using var stream = Assembly.GetExecutingAssembly().GetManifestResourceStream("devstack.default.yaml")
                           ?? throw new InvalidOperationException("Embedded devstack.default.yaml is missing.");
        using var reader = new StreamReader(stream);
        return reader.ReadToEnd();
    }

    public DevStackConfig Load()
    {
        lock (_lock)
        {
            var config = Parse(Common.SharedFile.ReadAllText(ConfigPath), ConfigPath, Workspace);
            // The daemon asked octo-tools (WorkspaceInfo): the file's octoToolsPath is not read, also when it did not answer.
            config.IgnoresFileOctoToolsPath = WorkspaceInfo != null;
            return config;
        }
    }

    /// <summary>Parses and validates a file; with a workspace the validation checks the profiles against its real folders.</summary>
    public static DevStackConfig Parse(string yaml, string source = "devstack.yaml", WorkspaceDefaults? workspace = null)
    {
        DevStackConfig config;
        try
        {
            config = Deserializer.Deserialize<DevStackConfig?>(yaml) ?? new DevStackConfig();
        }
        catch (YamlDotNet.Core.YamlException e)
        {
            throw new InvalidOperationException($"{source}: {e.Message} {e.InnerException?.Message}".Trim(), e);
        }

        config.Workspace = workspace;
        Validate(config, source);
        return config;
    }

    /// <summary>Applies a change and writes the file (previous version kept as .bak). The change runs on a fresh copy.</summary>
    public DevStackConfig Update(Action<DevStackConfig> change)
    {
        lock (_lock)
        {
            // With the workspace for the change's checks; what the file leaves out stays out of it.
            var config = Parse(Common.SharedFile.ReadAllText(ConfigPath), ConfigPath, Workspace);
            config.IgnoresFileOctoToolsPath = WorkspaceInfo != null;
            change(config);
            Validate(config, ConfigPath);
            var yaml = Serialize(config);
            File.Copy(ConfigPath, ConfigPath + ".bak", overwrite: true);
            var temp = ConfigPath + ".tmp";
            File.WriteAllText(temp, yaml);
            Common.SharedFile.Replace(temp, ConfigPath);
            return config;
        }
    }

    /// <summary>YAML of any object with the conventions of devstack.yaml (hashing, tool output).</summary>
    internal static string SerializeObject(object value) => Serializer.Serialize(value);

    public static string Serialize(DevStackConfig config)
    {
        return "# octo-devstack configuration (written by the daemon; see the repo's default for comments)\n" +
               Serializer.Serialize(config);
    }

    private static void Validate(DevStackConfig config, string source)
    {
        config.Slots ??= new Dictionary<string, SlotDefinition>();
        config.SlotOptions ??= new SlotOptions();
        config.EffectiveSlotDerivations = SlotDeriver.MergeTables(BuiltIn.SlotDerivations, config.SlotDerivations);

        foreach (var (name, service) in config.Services)
        {
            if (string.IsNullOrWhiteSpace(service.Repo))
            {
                throw new InvalidOperationException($"{source}: service '{name}' has no repo.");
            }

            if (string.IsNullOrWhiteSpace(service.Command))
            {
                throw new InvalidOperationException($"{source}: service '{name}' has no command.");
            }

            // The built-in dependencies are always kept (they are needed for a correct start: identity creates the system
            // database, the asset repository sets up the CK methods the controller checks): a devstack.yaml written before a
            // dependency was added to the default gets it without an edit. An own list adds to them; a dependency the file
            // does not configure is left out.
            var missing = BuiltInStartAfter(name).Where(d => config.Services.ContainsKey(d) && !service.StartAfter.Contains(d)).ToList();
            if (missing.Count > 0)
            {
                service.StartAfter = [.. service.StartAfter, .. missing];
            }

            foreach (var dependency in service.StartAfter)
            {
                if (!config.Services.ContainsKey(dependency))
                {
                    throw new InvalidOperationException($"{source}: service '{name}' starts after unknown service '{dependency}'.");
                }
            }

            foreach (var variable in service.Variables.Keys)
            {
                if (ServicePlanner.BuiltInVariables.Contains(variable))
                {
                    throw new InvalidOperationException($"{source}: variable '{variable}' of service '{name}' shadows a built-in placeholder.");
                }
            }
        }

        try
        {
            ServicePlanner.Order(config, config.Services.Keys.ToList());
        }
        catch (InvalidOperationException e)
        {
            throw new InvalidOperationException($"{source}: {e.Message}", e);
        }

        foreach (var (name, provider) in config.EnvProviders)
        {
            foreach (var service in provider.WhenServices)
            {
                if (!config.Services.ContainsKey(service))
                {
                    throw new InvalidOperationException($"{source}: env provider '{name}' names unknown service '{service}'.");
                }
            }
        }

        if (config.StopTimeoutSeconds is < 1 or > 300)
        {
            throw new InvalidOperationException($"{source}: stopTimeoutSeconds must be between 1 and 300.");
        }

        // "profiles:" without entries, or "name:" without a body, deserialize to null.
        config.Profiles ??= new Dictionary<string, Profile>();
        foreach (var name in config.Profiles.Where(p => p.Value == null).Select(p => p.Key).ToList())
        {
            config.Profiles[name] = new Profile();
        }

        SlotDeriver.ValidateTable(config, source);
        SlotRules.ValidateSlots(config, source);
        ProfileResolver.Validate(config, source);
    }
}
