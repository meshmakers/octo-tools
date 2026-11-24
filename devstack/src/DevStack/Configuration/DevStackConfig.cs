using System.ComponentModel;

namespace Meshmakers.Octo.DevStack.Configuration;

/// <summary>Root of devstack.yaml.</summary>
/// <summary>dockerVm: the size below which docker-marked test runs get a warning while kind runs in the same VM.</summary>
public sealed class DockerVmLimits
{
    public double MinMemoryGb { get; set; } = 12;
    public int MinCpus { get; set; } = 6;
}

public sealed class DevStackConfig
{
    public ServerConfig Server { get; set; } = new();

    // The machine's folders come from octo-tools (AB#9377): ConfigStore hands the workspace octo-tools describes
    // (Get-OctoWorkspace) to every config it loads. The daemon keeps no layout of its own, so without a workspace these
    // are empty and the folder problems say so. rootPath and defaultCheckout in the file override the workspace;
    // octo-tools is the one the daemon asked. Assigning a property sets the value of this config (copies, tests).

    /// <summary>The workspace's values for what the file leaves out; set by <see cref="ConfigStore"/>.</summary>
    [YamlDotNet.Serialization.YamlIgnore]
    [System.Text.Json.Serialization.JsonIgnore]
    public WorkspaceDefaults? Workspace { get; set; }

    [YamlDotNet.Serialization.YamlMember(Alias = "rootPath")]
    [System.Text.Json.Serialization.JsonIgnore]
    public string? RootPathSetting { get; set; }

    /// <summary>
    ///     octoToolsPath of a file before AB#9377. Not an override: the octo-tools the daemon asked for the workspace is the
    ///     one it uses (OCTO_TOOLS_PATH, --octo-tools). Read only by a config whose store asked no octo-tools (a test).
    /// </summary>
    [YamlDotNet.Serialization.YamlMember(Alias = "octoToolsPath")]
    [System.Text.Json.Serialization.JsonIgnore]
    public string? OctoToolsPathSetting { get; set; }

    /// <summary>
    ///     Set by <see cref="ConfigStore"/> when the daemon asked octo-tools for the workspace: the file's octoToolsPath is then
    ///     not read, also when octo-tools did not answer (nothing is guessed; the octo-tools path is empty then).
    /// </summary>
    [YamlDotNet.Serialization.YamlIgnore]
    [System.Text.Json.Serialization.JsonIgnore]
    public bool IgnoresFileOctoToolsPath { get; set; }

    // A value assigned in code (a copy of a config, a test), kept apart from the file's value.
    private string? _assignedOctoToolsPath;

    [YamlDotNet.Serialization.YamlMember(Alias = "defaultCheckout")]
    [System.Text.Json.Serialization.JsonIgnore]
    public string? DefaultCheckoutSetting { get; set; }

    [YamlDotNet.Serialization.YamlIgnore]
    public string RootPath
    {
        get => RootPathSetting ?? Workspace?.RootPath ?? "";
        set => RootPathSetting = value;
    }

    [YamlDotNet.Serialization.YamlIgnore]
    public string OctoToolsPath
    {
        get => Workspace?.OctoToolsPath ?? _assignedOctoToolsPath ?? (IgnoresFileOctoToolsPath ? null : OctoToolsPathSetting) ?? "";
        set => _assignedOctoToolsPath = value;
    }

    [YamlDotNet.Serialization.YamlIgnore]
    public string DefaultCheckout
    {
        get => DefaultCheckoutSetting ?? Workspace?.BaseLane ?? "";
        set => DefaultCheckoutSetting = value;
    }

    public string Configuration { get; set; } = "DebugL";
    public string TargetFramework { get; set; } = "net10.0";
    public string LogDirectory { get; set; } = "logFiles";
    public int StopTimeoutSeconds { get; set; } = 15;

    /// <summary>Below these the Docker VM is called small for test runs that start containers next to the kind cluster (a warning, AB#8835).</summary>
    public DockerVmLimits DockerVm { get; set; } = new();

    /// <summary>
    ///     Environment variables builds need (AB#9464), by name only: setup_check names a missing one. The built-in list of
    ///     devstack.default.yaml always applies; entries here add to it (same name: this one).
    /// </summary>
    public List<BuildVariable> BuildVariables { get; set; } = new();

    public Dictionary<string, string> Environment { get; set; } = new();
    public Dictionary<string, EnvProviderConfig> EnvProviders { get; set; } = new();
    public Dictionary<string, ServiceConfig> Services { get; set; } = new();

    /// <summary>Saved stack starts, see <see cref="Profile"/>. Optional; files without profiles keep loading.</summary>
    public Dictionary<string, Profile> Profiles { get; set; } = new();

    /// <summary>
    ///     Stack slots with a fixed index (and optional port offset / prefix). Optional: a slot named in stack_start that is
    ///     not listed here gets the next free index on first use.
    /// </summary>
    public Dictionary<string, SlotDefinition> Slots { get; set; } = new();

    /// <summary>What the daemon does around a slot start (identity overlay, smoke check).</summary>
    public SlotOptions SlotOptions { get; set; } = new();

    /// <summary>
    ///     The user's changes to the slot derivation table; null keeps the built-in table of devstack.default.yaml. Rows
    ///     replace built-in rows of the same id, new ids are added.
    /// </summary>
    public SlotDerivationConfig? SlotDerivations { get; set; }

    /// <summary>The built-in table merged with <see cref="SlotDerivations"/>; filled when the file is loaded, never written.</summary>
    [YamlDotNet.Serialization.YamlIgnore]
    public SlotDerivationConfig EffectiveSlotDerivations { get; set; } = new();
}

/// <summary>A slot of devstack.yaml: index (1, 2, ...), and optionally its port offset (default 100 * index) and data prefix (default s&lt;index&gt;).</summary>
public sealed class SlotDefinition
{
    public int Index { get; set; }
    public int? PortOffset { get; set; }
    public string? Prefix { get; set; }
}

public sealed class SlotOptions
{
    /// <summary>
    ///     After a start of a non-default slot that brought its identity service up healthy, run the slot's setup (stack_setup:
    ///     admin of a fresh system database, octo-cli installation entry and contexts, login, identity overlay). Every step is
    ///     idempotent; a later start only logs the contexts in again.
    /// </summary>
    public bool AutoSetup { get; set; } = true;

    /// <summary>Replaced by <see cref="AutoSetup"/> (the overlay is one of its steps); read so older files still load, never written.</summary>
    public bool? ApplyIdentityOverlay
    {
        get => null;
        set { }
    }

    /// <summary>After a slot started: GET the identity discovery document and compare its issuer with the slot's authority URL.</summary>
    public bool SmokeCheck { get; set; } = true;
}

/// <summary>
///     How a non-default slot derives its values: shift every port, and the rows of environment keys rendered from
///     placeholders ({slot.name}, {slot.index}, {slot.prefix}, {slot.offset}, {port.&lt;service&gt;.&lt;n|https|http&gt;},
///     {shift:&lt;port&gt;}, {slotDir}, {service}).
/// </summary>
public sealed class SlotDerivationConfig
{
    /// <summary>Shift ports, health URLs, the ports in --urls arguments and announced URLs by the slot's port offset.</summary>
    public bool? PortShift { get; set; }

    public List<SlotDerivationRow> Rows { get; set; } = new();
}

public sealed class SlotDerivationRow
{
    public string Id { get; set; } = "";

    /// <summary>Environment keys; an entry "@name" stands for a shared key list (SettingsMap.KeyLists).</summary>
    public List<string> Keys { get; set; } = new();

    public string Value { get; set; } = "";

    /// <summary>Only these services (and their instances) get the value, in their own env; default: the stack environment.</summary>
    public List<string>? Services { get; set; }

    /// <summary>Condition such as "slot.index > 1"; default: every non-default slot.</summary>
    public string? When { get; set; }

    /// <summary>The value names data of the slot: it must differ from the value of every other running slot.</summary>
    public bool Isolate { get; set; }

    /// <summary>Removes a built-in row of the same id (user file only).</summary>
    public bool Disabled { get; set; }
}

/// <summary>An environment variable the builds of some repositories need; its value is never configured here.</summary>
public sealed class BuildVariable
{
    public string Name { get; set; } = "";

    /// <summary>Checked only when the default lane holds one of these repositories.</summary>
    public List<string> Repos { get; set; } = new();

    /// <summary>What the builds use it for (shown by setup_check).</summary>
    public string? Why { get; set; }
}

/// <summary>Where the daemon listens.</summary>
public sealed class ServerConfig
{
    public string Url { get; set; } = "http://127.0.0.1:5090";
}

/// <summary>A PowerShell snippet returning a hashtable of environment variables.</summary>
public sealed class EnvProviderConfig
{
    public bool Enabled { get; set; } = true;
    public string Script { get; set; } = "";
    public List<string> WhenServices { get; set; } = new();
}

/// <summary>One process of the stack.</summary>
public sealed class ServiceConfig
{
    public string? Description { get; set; }

    /// <summary>Folder of the repository inside the checkout (e.g. octo-identity-services).</summary>
    public string Repo { get; set; } = "";

    /// <summary>Relative to the repository folder.</summary>
    public string WorkingDirectory { get; set; } = "bin/${configuration}/${tfm}";

    public string Command { get; set; } = "dotnet";
    public List<string> Args { get; set; } = new();
    public Dictionary<string, string> Env { get; set; } = new();
    public Dictionary<string, string> Variables { get; set; } = new();
    public Dictionary<string, string> AnnounceEnv { get; set; } = new();
    public List<int> Ports { get; set; } = new();
    public string? HealthUrl { get; set; }
    public bool Enabled { get; set; } = true;
    public bool Optional { get; set; }

    /// <summary>Log file name without extension; defaults to the service name.</summary>
    public string? LogName { get; set; }

    /// <summary>
    ///     Services that must be healthy before this one starts (when they run or are started in the same start; a start that
    ///     names this service brings the ones that do not run, SlotRun.MissingDependencies). A service
    ///     whose dependency exits or is not healthy within the start's timeout is not started. Empty: the built-in service of
    ///     the same name gives the list (restricted to configured services), so older devstack.yaml files get new defaults.
    /// </summary>
    public List<string> StartAfter { get; set; } = new();

    /// <summary>
    ///     Runs in the default slot only (frontends with fixed ports and redirect URIs). Unset: the value of the built-in
    ///     service of the same name, so files written before slots existed keep the frontends out of other slots.
    /// </summary>
    public bool? Exclusive { get; set; }

    /// <summary>
    ///     How the service runs in a non-default slot when that differs from the default slot: a frontend whose dev server
    ///     has a fixed port and a tracked config runs from its build output instead. Only the fields given replace the
    ///     service's own; they take the slot placeholders ({port.&lt;service&gt;.&lt;n&gt;}, {filesDir}, {slotDir}, ...).
    /// </summary>
    public ServiceSlotVariant? Slot { get; set; }

    /// <summary>
    ///     Files generated for the service in a non-default slot, into {filesDir} (&lt;state&gt;/slots/&lt;slot&gt;/services/&lt;service&gt;),
    ///     never into the repository: e.g. a frontend's runtime config with the slot's backend URLs.
    /// </summary>
    public List<ServiceFile> Files { get; set; } = new();

    /// <summary>OIDC clients of the service whose redirect URIs follow its port: added to the slot's identity overlay.</summary>
    public List<ServiceIdentityClient> IdentityClients { get; set; } = new();

    /// <summary>Repositories that must be in a feature environment together with this service's repo (its build uses them as siblings).</summary>
    public List<string> RequiresRepos { get; set; } = new();

    /// <summary>A deep copy (materialized profile instances are clones of their base service).</summary>
    public ServiceConfig Clone() => new()
    {
        Description = Description,
        Repo = Repo,
        WorkingDirectory = WorkingDirectory,
        Command = Command,
        Args = [..Args],
        Env = new Dictionary<string, string>(Env),
        Variables = new Dictionary<string, string>(Variables),
        AnnounceEnv = new Dictionary<string, string>(AnnounceEnv),
        Ports = [..Ports],
        HealthUrl = HealthUrl,
        Enabled = Enabled,
        Optional = Optional,
        LogName = LogName,
        StartAfter = [..StartAfter],
        Exclusive = Exclusive,
        Slot = Slot?.Clone(),
        Files = Files.Select(f => f.Clone()).ToList(),
        IdentityClients = IdentityClients.Select(c => c.Clone()).ToList(),
        RequiresRepos = [..RequiresRepos]
    };
}

/// <summary>What replaces a service's start in a non-default slot (see <see cref="ServiceConfig.Slot"/>).</summary>
public sealed class ServiceSlotVariant
{
    public string? Command { get; set; }
    public List<string>? Args { get; set; }

    /// <summary>Relative to the repository folder.</summary>
    public string? WorkingDirectory { get; set; }

    public string? HealthUrl { get; set; }

    /// <summary>Added to the service's env (a slot value wins over the service's own).</summary>
    public Dictionary<string, string>? Env { get; set; }

    public ServiceSlotVariant Clone() => new()
    {
        Command = Command, Args = Args == null ? null : [..Args], WorkingDirectory = WorkingDirectory, HealthUrl = HealthUrl,
        Env = Env == null ? null : new Dictionary<string, string>(Env)
    };
}

/// <summary>
///     A generated file of a service: <see cref="Path"/> below {filesDir}; the content is the JSON file <see cref="From"/>
///     of the repository (relative to the folder the service runs from) with the top-level keys of <see cref="Set"/>
///     replaced by their rendered values (slot placeholders). Without <see cref="From"/> the file holds only the set keys.
/// </summary>
public sealed class ServiceFile
{
    public string Path { get; set; } = "";
    public string? From { get; set; }
    public Dictionary<string, string> Set { get; set; } = new();

    public ServiceFile Clone() => new() { Path = Path, From = From, Set = new Dictionary<string, string>(Set) };
}

/// <summary>
///     An OIDC client whose URIs name the service's origin. <see cref="Tenant"/>: the tenant that holds the client (default:
///     the system tenant); clients of another tenant go into their own overlay file, applied through that tenant's context.
/// </summary>
public sealed class ServiceIdentityClient
{
    public string ClientId { get; set; } = "";
    public string? Tenant { get; set; }
    public List<string> RedirectUris { get; set; } = new();
    public List<string> PostLogoutRedirectUris { get; set; } = new();
    public List<string> AllowedCorsOrigins { get; set; } = new();

    public ServiceIdentityClient Clone() => new()
    {
        ClientId = ClientId, Tenant = Tenant, RedirectUris = [..RedirectUris], PostLogoutRedirectUris = [..PostLogoutRedirectUris],
        AllowedCorsOrigins = [..AllowedCorsOrigins]
    };
}

/// <summary>
///     One stack start request: what <c>stack_start</c> takes ad hoc and what a <see cref="Profile"/> saves. Every field is
///     optional; unset fields come from earlier layers (devstack.yaml root, the profiles a profile extends).
/// </summary>
public class StartSpec
{
    [Description("Lane to run from, relative to rootPath (e.g. 'branches/main') or absolute.")]
    public string? Checkout { get; set; }

    [Description("Build configuration whose bin folders are used: DebugL, Release or Debug.")]
    public string? Configuration { get; set; }

    [Description("Services to start; replaces the inherited list. Default: every enabled service.")]
    public List<string>? Services { get; set; }

    [Description("Services to leave out; adds to the inherited list.")]
    public List<string>? Exclude { get; set; }

    [Description("Per-service changes keyed by service (or instance) name: source ('lane:<name>' or a folder), args, extraArgs, envVars, variables.")]
    public Dictionary<string, ServiceOverride>? Overrides { get; set; }

    [Description("Environment variables for every service of the stack; a null value removes one.")]
    public Dictionary<string, string?>? Environment { get; set; }

    [Description("Extra processes of a configured service, keyed by instance name, e.g. a second mesh adapter on other ports.")]
    public Dictionary<string, ProfileInstance>? Instances { get; set; }

    [Description("Turn env providers on (true) or off (false) for this start, keyed by provider name.")]
    public Dictionary<string, bool>? EnvProviders { get; set; }

    [Description("Logical settings that fan out to the environment keys of every service that holds them.")]
    public ProfileSettings? Settings { get; set; }

    [Description("Fail the start (instead of warning) when the kind infrastructure ports do not answer.")]
    public bool? RequireInfra { get; set; }

    [Description("Stack slot to run in (lowercase letters, digits, -). Default: 'default' (the configured ports and data names). Another slot shifts every port and isolates its data (system database, instance prefixes, storage paths).")]
    public string? Slot { get; set; }
}

/// <summary>A saved stack start: which services, from where, with which configuration.</summary>
public sealed class Profile : StartSpec
{
    [Description("What the profile is for, shown in profile_list and on the status page.")]
    public string? Description { get; set; }

    [Description("Name of a profile whose values this one starts from (its own fields win).")]
    public string? Extends { get; set; }
}

/// <summary>An extra process of a configured service (<see cref="Of"/>), materialized as a clone of it.</summary>
public sealed class ProfileInstance : ServiceOverride
{
    [Description("The configured service this instance is a copy of, e.g. 'meshAdapter'.")]
    public string? Of { get; set; }

    [Description("Ports of the instance; without them it uses the ports of its base service (which clashes when both run).")]
    public List<int>? Ports { get; set; }

    [Description("Health URL of the instance; default the one of the base service.")]
    public string? HealthUrl { get; set; }

    [Description("Log file name without .log; default the instance name.")]
    public string? LogName { get; set; }
}

/// <summary>
///     Settings the services keep in different configuration sections (there is no shared section); see SettingsMap for
///     the keys each one fans out to. Credentials are deliberately not settings.
/// </summary>
public sealed class ProfileSettings
{
    [Description("System database name (OCTO_SYSTEM__SYSTEMDATABASENAME), e.g. 'OctoSystem_fresh' for an empty system.")]
    public string? SystemDatabase { get; set; }

    public MongoSettings? Mongo { get; set; }

    public BrokerSettings? Broker { get; set; }

    [Description("Identity issuer every service validates against (Authority/AuthorityUrl/IssuerUri of each service).")]
    public string? AuthorityUrl { get; set; }

    public StreamDataSettings? StreamData { get; set; }

    [Description("'fileSystem' or 'localS3' (the s3Store env provider on).")]
    public string? ArtifactStorage { get; set; }

    public MeshAdapterSettings? MeshAdapter { get; set; }

    public HttpActivatorSettings? HttpActivator { get; set; }

    [Description("Default log level of every service (OCTO_LOGGING__LOGLEVEL__DEFAULT), e.g. 'Debug'.")]
    public string? LogLevel { get; set; }
}

public sealed class MongoSettings
{
    public string? Host { get; set; }
    public bool? DirectConnection { get; set; }
    public string? ReplicaSet { get; set; }
}

public sealed class BrokerSettings
{
    public string? Host { get; set; }
    public int? Port { get; set; }
    public string? Vhost { get; set; }
    public string? InstancePrefix { get; set; }
}

public sealed class StreamDataSettings
{
    public bool? Enabled { get; set; }
    public string? SchemaInstancePrefix { get; set; }
}

public sealed class MeshAdapterSettings
{
    [Description("Tenant of the mesh adapter (variable tenantId of meshAdapter).")]
    public string? TenantId { get; set; }

    [Description("Runtime id of the adapter entity (variable adapterId of meshAdapter).")]
    public string? AdapterRtId { get; set; }
}

public sealed class HttpActivatorSettings
{
    public bool? Enabled { get; set; }
    public string? AddressTemplate { get; set; }
}
