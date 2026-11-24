using System.ComponentModel;

namespace Meshmakers.Octo.DevStack.Configuration;

/// <summary>Per-start changes of one service; nothing of it is persisted.</summary>
public class ServiceOverride
{
    [Description("Run the service from another folder than the stack's own repo: 'lane:<name>' (that lane's worktree of the service's repo, e.g. " +
                 "'lane:ab8625-enum-null' - a lane's build in the shared stack), or a folder of the repo (a worktree) relative to the stack's base lane, " +
                 "to rootPath, or absolute. It must have been built for the stack's configuration (lane_build / base_build).")]
    public string? Source { get; set; }

    [Description("Replace the configured arguments completely.")]
    public List<string>? Args { get; set; }

    [Description("Append these arguments to the configured (or replaced) ones, e.g. '--Logging:LogLevel:Default=Debug'.")]
    public List<string>? ExtraArgs { get; set; }

    [Description("Environment variables for this service; a null value removes a variable.")]
    [System.Text.Json.Serialization.JsonPropertyName("envVars")]
    public Dictionary<string, string?>? Env { get; set; }

    [Description("Values for the service's variables, e.g. {\"tenantId\": \"mytenant\"} for meshAdapter.")]
    public Dictionary<string, string>? Variables { get; set; }
}

/// <summary>Where and how a stack runs.</summary>
public sealed record StackContext(string RootPath, string Checkout, string Configuration, string TargetFramework, string LogDirectory)
{
    /// <summary>
    ///     The feature environment the checkout is (&lt;rootPath&gt;/wt-&lt;env&gt;), else null. A service whose repo the
    ///     environment does not hold runs from <see cref="Base"/>.
    /// </summary>
    public string? Environment { get; init; }

    /// <summary>The environment's base lane (e.g. branches/main): the second link of the source chain.</summary>
    public string? Base { get; init; }

    /// <summary>The environment's repos and where they are (manifest path; may lie outside the environment folder).</summary>
    public IReadOnlyDictionary<string, string>? EnvironmentRepos { get; init; }

    /// <summary>
    ///     The repo folder a service runs from without a source override: &lt;checkout&gt;/&lt;repo&gt;; for an environment the
    ///     manifest's path of the repo, or &lt;base&gt;/&lt;repo&gt; when the environment does not hold it.
    /// </summary>
    public string RepoPath(string repo)
    {
        if (Environment == null)
        {
            return System.IO.Path.Combine(Checkout, repo);
        }

        if (EnvironmentRepos != null && EnvironmentRepos.TryGetValue(repo, out var own))
        {
            return own;
        }

        return System.IO.Path.Combine(Base ?? Checkout, repo);
    }
}

/// <summary>Everything needed to start one process.</summary>
public sealed record ServicePlan(
    string Name,
    string RepoPath,
    string WorkingDirectory,
    string Command,
    IReadOnlyList<string> Args,
    IReadOnlyDictionary<string, string?> Env,
    string LogFile,
    IReadOnlyList<int> Ports,
    string? HealthUrl,
    IReadOnlyList<string> StartAfter,
    string? Source);

public static class ServicePlanner
{
    public static readonly HashSet<string> BuiltInVariables = ["rootPath", "checkout", "repoPath", "configuration", "tfm", "service", "home", "daemon"];

    /// <summary>The daemon's own assembly (${daemon}): services that are helper modes of it (--serve-app) start `dotnet ${daemon} ...`.</summary>
    public static string DaemonAssembly { get; } = typeof(ServicePlanner).Assembly.Location;

    /// <summary>The workspace root; empty when octo-tools did not describe the workspace and the file sets no rootPath.</summary>
    public static string RootPath(DevStackConfig config) => config.RootPath.Length == 0 ? "" : TemplateExpander.ExpandPath(config.RootPath);

    /// <summary>The octo-tools the daemon asked for the workspace; empty when it found none.</summary>
    public static string OctoToolsPath(DevStackConfig config)
    {
        if (config.OctoToolsPath.Length == 0)
        {
            return "";
        }

        var root = RootPath(config);
        return TemplateExpander.ExpandPath(TemplateExpander.Expand(config.OctoToolsPath, new Dictionary<string, string> { ["rootPath"] = root, ["home"] = Home }));
    }

    private static string KnownRoot(DevStackConfig config) => RootPath(config) is { Length: > 0 } root
        ? root
        : throw new InvalidOperationException("The workspace is unknown: octo-tools did not describe it (setup_check names why). Update octo-tools (git pull) and restart the daemon.");

    private static string Home => Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);

    /// <summary>
    ///     What is wrong with rootPath and defaultCheckout: folders that do not exist (octo-tools described another machine,
    ///     or an override in the file is stale). Empty when both exist. Shown by stack_status, the status page, setup_check
    ///     and the daemon's start log.
    /// </summary>
    public static List<string> FolderProblems(DevStackConfig config, string? configPath = null)
    {
        var problems = new List<string>();
        var where = configPath == null ? "devstack.yaml" : configPath;
        var root = RootPath(config);
        if (root.Length == 0)
        {
            problems.Add("The workspace is unknown: octo-tools did not describe it (config_get.workspace.problems, setup_check). " +
                         "Update octo-tools (git pull) and restart the daemon.");
            return problems;
        }

        if (!Directory.Exists(root))
        {
            problems.Add($"rootPath '{config.RootPath}' ({root}) does not exist: {(config.RootPathSetting != null ? $"remove rootPath from {where} (octo-tools describes the workspace) or correct it" : "octo-tools describes a folder that is gone; check config_get.workspace")}.");
            return problems;
        }

        if (config.DefaultCheckout.Length == 0)
        {
            // An empty value would resolve to the root itself and hide that no lane is known.
            problems.Add($"The default lane is unknown: octo-tools did not name one and {where} sets no defaultCheckout. " +
                         "Update octo-tools (git pull), set defaultCheckout, or pass baseLane to stack_start.");
            return problems;
        }

        try
        {
            ResolveFolder(config.DefaultCheckout, root, null, "base lane");
        }
        catch (InvalidOperationException)
        {
            problems.Add($"defaultCheckout '{config.DefaultCheckout}' does not exist below rootPath {root}: set defaultCheckout in {where}, " +
                         "or pass baseLane to stack_start.");
        }

        return problems;
    }

    public static StackContext CreateContext(DevStackConfig config, string? checkout, string? configuration)
    {
        var root = KnownRoot(config);
        var lane = checkout ?? (config.DefaultCheckout.Length > 0
            ? config.DefaultCheckout
            : throw new InvalidOperationException("The default lane is unknown: octo-tools did not describe the workspace. Pass baseLane, or update octo-tools (git pull)."));
        var checkoutPath = ResolveFolder(lane, root, null, "base lane");
        var logDirectory = Path.GetFullPath(Path.Combine(checkoutPath, config.LogDirectory));
        var context = new StackContext(root, checkoutPath, configuration ?? config.Configuration, config.TargetFramework, logDirectory);
        if (Discovery.EnvironmentDiscovery.OfCheckout(checkoutPath, root) is not { } env)
        {
            return context;
        }

        if (env.Problem != null)
        {
            throw new InvalidOperationException($"The folder {checkoutPath} is lane '{env.Name}', which cannot be used: {env.Problem}");
        }

        return context with { Environment = env.Name, Base = env.BasePath, EnvironmentRepos = env.RepoPaths() };
    }

    /// <summary>Resolves a folder that is absolute, relative to <paramref name="first"/> or relative to <paramref name="root"/>.</summary>
    public static string ResolveFolder(string value, string root, string? first, string what)
    {
        var candidates = new List<string>();
        if (value.StartsWith('~') || Path.IsPathRooted(value))
        {
            candidates.Add(TemplateExpander.ExpandPath(value));
        }
        else
        {
            if (first != null)
            {
                candidates.Add(Path.GetFullPath(Path.Combine(first, value)));
            }

            candidates.Add(Path.GetFullPath(Path.Combine(root, value)));
        }

        foreach (var candidate in candidates)
        {
            if (Directory.Exists(candidate))
            {
                return candidate.TrimEnd(Path.DirectorySeparatorChar);
            }
        }

        throw new InvalidOperationException($"The {what} '{value}' does not exist (looked at: {string.Join(", ", candidates)}).");
    }

    public static Dictionary<string, string> BuiltIns(StackContext context, string service, string repoPath) => new()
    {
        ["rootPath"] = context.RootPath,
        ["checkout"] = context.Checkout,
        ["repoPath"] = repoPath,
        ["configuration"] = context.Configuration,
        ["tfm"] = context.TargetFramework,
        ["service"] = service,
        ["home"] = Home,
        ["daemon"] = DaemonAssembly
    };

    /// <summary>
    ///     Builds the plan of one service. Environment order (later wins): config environment, <paramref name="stackEnv"/>
    ///     (env providers, announced URLs, per-start env), service env, override env. A null value removes the variable.
    /// </summary>
    public static ServicePlan Plan(DevStackConfig config, StackContext context, string name, ServiceOverride? overrides,
        IReadOnlyDictionary<string, string?> stackEnv)
    {
        if (!config.Services.TryGetValue(name, out var service))
        {
            throw new InvalidOperationException($"Unknown service '{name}'. Configured: {string.Join(", ", config.Services.Keys)}.");
        }

        // The source chain: an override, else the checkout's repo, else (environment) the base lane's repo.
        var defaultRepoPath = context.RepoPath(service.Repo);
        var repoPath = overrides?.Source is { Length: > 0 } source
            ? LaneSource.Is(source) ? LaneSource.Resolve(config, name, service.Repo, source) : ResolveFolder(source, context.RootPath, context.Checkout, $"source of service '{name}'")
            : defaultRepoPath;

        var variables = BuiltIns(context, name, repoPath);
        foreach (var (key, value) in service.Variables)
        {
            variables[key] = value;
        }

        foreach (var (key, value) in overrides?.Variables ?? [])
        {
            if (BuiltInVariables.Contains(key))
            {
                throw new InvalidOperationException($"Variable '{key}' is built in and cannot be overridden.");
            }

            if (!service.Variables.ContainsKey(key))
            {
                throw new InvalidOperationException(
                    $"Service '{name}' has no variable '{key}'. Its variables: {(service.Variables.Count == 0 ? "none" : string.Join(", ", service.Variables.Keys))}.");
            }

            variables[key] = value;
        }

        string X(string template) => TemplateExpander.Expand(template, variables);

        var args = (overrides?.Args ?? service.Args).Concat(overrides?.ExtraArgs ?? []).Select(X).ToList();

        var env = new Dictionary<string, string?>(StringComparer.Ordinal);
        foreach (var (key, value) in config.Environment)
        {
            env[key] = X(value);
        }

        foreach (var (key, value) in stackEnv)
        {
            env[key] = value;
        }

        foreach (var (key, value) in service.Env)
        {
            env[key] = X(value);
        }

        foreach (var (key, value) in overrides?.Env ?? [])
        {
            env[key] = value == null ? null : X(value);
        }

        var workingDirectory = Path.GetFullPath(Path.Combine(repoPath, X(service.WorkingDirectory)));
        var logFile = Path.Combine(context.LogDirectory, (service.LogName ?? name) + ".log");

        return new ServicePlan(name, repoPath, workingDirectory, X(service.Command), args, env, logFile,
            service.Ports.ToList(), service.HealthUrl is null ? null : X(service.HealthUrl), service.StartAfter.ToList(),
            repoPath == defaultRepoPath ? null : repoPath);
    }

    /// <summary>
    ///     The stack environment of a start (later wins): env providers, the URLs announced by the services that will run,
    ///     the slot's derived rows, then the request env (settings fan-out, profile and stack_start env). Config environment
    ///     comes before and service/override env after it (<see cref="Plan"/>).
    /// </summary>
    public static Dictionary<string, string?> StackEnv(DevStackConfig config, IEnumerable<string> services, IReadOnlyDictionary<string, string?> providerEnv,
        IReadOnlyDictionary<string, string> slotEnv, IReadOnlyDictionary<string, string?> requestEnv)
    {
        var env = new Dictionary<string, string?>(providerEnv, StringComparer.Ordinal);
        foreach (var name in services)
        {
            foreach (var (key, value) in config.Services[name].AnnounceEnv)
            {
                env[key] = value;
            }
        }

        foreach (var (key, value) in slotEnv)
        {
            env[key] = value;
        }

        foreach (var (key, value) in requestEnv)
        {
            env[key] = value;
        }

        return env;
    }

    /// <summary>Orders services so that every service comes after the ones it starts after (within the set).</summary>
    public static List<string> Order(DevStackConfig config, IReadOnlyCollection<string> names)
    {
        var result = new List<string>();
        var state = new Dictionary<string, int>();

        void Visit(string name, Stack<string> path)
        {
            if (state.TryGetValue(name, out var s))
            {
                if (s == 1)
                {
                    throw new InvalidOperationException($"startAfter cycle: {string.Join(" -> ", path.Reverse().Append(name))}.");
                }

                return;
            }

            state[name] = 1;
            path.Push(name);
            foreach (var dependency in config.Services[name].StartAfter.Where(names.Contains))
            {
                Visit(dependency, path);
            }

            path.Pop();
            state[name] = 2;
            result.Add(name);
        }

        foreach (var name in names)
        {
            Visit(name, new Stack<string>());
        }

        return result;
    }
}
