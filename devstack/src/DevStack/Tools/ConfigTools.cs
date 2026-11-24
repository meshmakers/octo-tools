using System.ComponentModel;
using Meshmakers.Octo.DevStack.Common;
using Meshmakers.Octo.DevStack.Configuration;
using ModelContextProtocol.Server;

namespace Meshmakers.Octo.DevStack.Tools;

public sealed record ServiceView(
    string Name,
    string? Description,
    string Repo,
    string WorkingDirectory,
    string Command,
    IReadOnlyList<string> Args,
    IReadOnlyDictionary<string, string> EnvVars,
    IReadOnlyDictionary<string, string> Variables,
    IReadOnlyDictionary<string, string> AnnounceEnv,
    IReadOnlyList<int> Ports,
    string? HealthUrl,
    bool Enabled,
    bool Optional,
    string LogName,
    IReadOnlyList<string> StartAfter);

public sealed record EnvProviderView(string Name, bool Enabled, IReadOnlyList<string> WhenServices, string Script);

public sealed record ConfigView(
    string ConfigPath,
    string RootPath,
    string OctoToolsPath,
    string BaseLane,
    string Configuration,
    string TargetFramework,
    string LogDirectory,
    int StopTimeoutSeconds,
    IReadOnlyDictionary<string, string> EnvVars,
    IReadOnlyList<EnvProviderView> EnvProviders,
    IReadOnlyList<ServiceView> Services,
    IReadOnlyList<string> Profiles,
    [property: System.Text.Json.Serialization.JsonIgnore(Condition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull)]
    WorkspaceInfo? Workspace = null,
    IReadOnlyList<string>? Overrides = null);

/// <summary>What admin_config_import_defaults copied, and what the built-in default still has that the file lacks.</summary>
public sealed record DefaultsImport(IReadOnlyList<string> ImportedServices, IReadOnlyList<string> ImportedProfiles, IReadOnlyList<string> MissingServices,
    IReadOnlyList<string> MissingProfiles, [property: System.Text.Json.Serialization.JsonIgnore(Condition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull)] string? Note);

/// <summary>Read and change devstack.yaml. Changes apply to the next start of a service.</summary>
[McpServerToolType]
public sealed class ConfigTools(ConfigStore store, ILogger<ConfigTools> logger)
{
    [McpServerTool(Name = "config_get", ReadOnly = true)]
    [Description("Shows the devstack configuration as written: defaults (base lane = defaultCheckout, configuration), global environment " +
                 "variables, env providers and every service with repo, command, arguments, environment variables, variables, ports, and the " +
                 "profile names (details: profile_get). Service names here are what stack_start / service_* take. Secret-looking values are " +
                 "masked. Read-only.")]
    public ConfigView Get() => ToolGuard.Run(() => View(store.Load()));

    [McpServerTool(Name = "admin_service_define")]
    [Description("Admin (the developer's go): adds a service to devstack.yaml, or changes fields of an existing one (only the fields you pass " +
                 "change; lists and maps are replaced as a whole). Applies to the next start/restart of the service in every stack. A new " +
                 "service needs at least repo and args. Example: a .NET service in <base lane>/octo-foo/bin/<configuration>/net10.0: " +
                 "repo='octo-foo', args=['Meshmakers.Octo.Foo.dll','--urls=https://0.0.0.0:5031;http://0.0.0.0:5030'], ports=[5031,5030].")]
    public ServiceView Define(
        [Description("Who changes the config (logged).")] string owner,
        [Description("Service name (letters, digits, -, _).")] string name,
        [Description("Repository folder in the base lane, e.g. 'octo-identity-services'.")] string? repo = null,
        [Description("Working directory relative to the repository folder. Default 'bin/${configuration}/${tfm}'.")] string? workingDirectory = null,
        [Description("Executable, default 'dotnet'.")] string? command = null,
        [Description("Arguments; placeholders like ${configuration}, ${checkout}, ${repoPath}, ${<variable>} are expanded.")] List<string>? args = null,
        [Description("Environment variables of the service.")] Dictionary<string, string>? envVars = null,
        [Description("Named values for placeholders in args/envVars, overridable per start (overrides.<service>.variables).")] Dictionary<string, string>? variables = null,
        [Description("Environment set for ALL services of a start that includes this one, e.g. a URL other services discover it by.")]
        Dictionary<string, string>? announceEnv = null,
        [Description("TCP ports; checked for conflicts before the start, the first one is the default health probe.")] List<int>? ports = null,
        [Description("URL whose answer below HTTP 500 counts as healthy (instead of the port probe).")] string? healthUrl = null,
        [Description("Part of a stack start without an explicit service list.")] bool? enabled = null,
        [Description("Skip (instead of fail) when not built.")] bool? optional = null,
        [Description("Log file name without .log; default the service name.")] string? logName = null,
        [Description("Services that must be healthy before this one starts; empty: the built-in service's list.")] List<string>? startAfter = null,
        [Description("What the service is.")] string? description = null,
        [Description(StackTools.SessionDescription)] string? session = null) =>
        ToolGuard.Run(() =>
        {
            if (string.IsNullOrWhiteSpace(name) || !name.All(c => char.IsAsciiLetterOrDigit(c) || c is '-' or '_'))
            {
                throw new ArgumentException($"Invalid service name '{name}'.");
            }

            var created = false;
            var config = store.Update(c =>
            {
                if (!c.Services.TryGetValue(name, out var service))
                {
                    if (repo == null || args == null)
                    {
                        throw new ArgumentException($"Service '{name}' does not exist; a new service needs repo and args.");
                    }

                    service = new ServiceConfig();
                    c.Services[name] = service;
                    created = true;
                }

                if (repo != null) service.Repo = repo;
                if (workingDirectory != null) service.WorkingDirectory = workingDirectory;
                if (command != null) service.Command = command;
                if (args != null) service.Args = args;
                if (envVars != null) service.Env = envVars;
                if (variables != null) service.Variables = variables;
                if (announceEnv != null) service.AnnounceEnv = announceEnv;
                if (ports != null) service.Ports = ports;
                if (healthUrl != null) service.HealthUrl = healthUrl.Length == 0 ? null : healthUrl;
                if (enabled != null) service.Enabled = enabled.Value;
                if (optional != null) service.Optional = optional.Value;
                if (logName != null) service.LogName = logName.Length == 0 ? null : logName;
                if (startAfter != null) service.StartAfter = startAfter;
                if (description != null) service.Description = description;
            });
            logger.LogInformation("{Owner} ({Session}) {Action} service {Service}", owner, session ?? "-", created ? "added" : "changed", name);
            return ViewService(name, config.Services[name]);
        });

    [McpServerTool(Name = "admin_service_remove", Destructive = true)]
    [Description("Admin (the developer's go): removes a service from devstack.yaml (also from the services/exclude/overrides of profiles). A " +
                 "running instance keeps running until it is stopped.")]
    public string Remove(
        [Description("Who changes the config (logged).")] string owner,
        [Description("Service name.")] string name,
        [Description(StackTools.SessionDescription)] string? session = null) =>
        ToolGuard.Run(() =>
        {
            store.Update(c =>
            {
                if (!c.Services.Remove(name))
                {
                    throw new InvalidOperationException($"Unknown service '{name}'.");
                }

                foreach (var other in c.Services.Values)
                {
                    other.StartAfter.Remove(name);
                }

                foreach (var provider in c.EnvProviders.Values)
                {
                    provider.WhenServices.Remove(name);
                }

                foreach (var (profileName, profile) in c.Profiles)
                {
                    if (profile.Instances?.Values.Any(i => i.Of == name) == true)
                    {
                        throw new InvalidOperationException($"Profile '{profileName}' has an instance of '{name}'; change the profile first.");
                    }

                    profile.Services?.Remove(name);
                    profile.Exclude?.Remove(name);
                    profile.Overrides?.Remove(name);
                }
            });
            logger.LogInformation("{Owner} ({Session}) removed service {Service}", owner, session ?? "-", name);
            return $"Service '{name}' removed.";
        });

    [McpServerTool(Name = "admin_envvar_set")]
    [Description("Admin (the developer's go): sets or removes (value=null) an environment variable in devstack.yaml, globally for all services " +
                 "or for one service, in every stack. Applies to services started from now on. For a one-off value use stack_start(envVars) " +
                 "or overrides.<service>.envVars instead.")]
    public string EnvSet(
        [Description("Who changes the config (logged).")] string owner,
        [Description("Variable name, e.g. 'Logging__LogLevel__Default'.")] string name,
        [Description("Value; null removes the variable.")] string? value = null,
        [Description("Service name; omit for the global environment variables.")] string? service = null,
        [Description(StackTools.SessionDescription)] string? session = null) =>
        ToolGuard.Run(() =>
        {
            store.Update(c =>
            {
                Dictionary<string, string> target;
                if (service == null)
                {
                    target = c.Environment;
                }
                else if (c.Services.TryGetValue(service, out var s))
                {
                    target = s.Env;
                }
                else
                {
                    throw new InvalidOperationException($"Unknown service '{service}'.");
                }

                if (value == null)
                {
                    target.Remove(name);
                }
                else
                {
                    target[name] = value;
                }
            });
            logger.LogInformation("{Owner} ({Session}) {Action} environment variable {Name} ({Scope})", owner, session ?? "-", value == null ? "removed" : "set",
                name, service ?? "global");
            return $"{name} {(value == null ? "removed" : "set")} ({service ?? "global"}). Restart the affected services to apply it.";
        });

    [McpServerTool(Name = "admin_config_import_defaults")]
    [Description("Admin (the developer's go): copies services and profiles of the built-in default configuration into devstack.yaml - for definitions a newer daemon " +
                 "brings that an existing devstack.yaml does not have yet (the file is written once, on the first start), e.g. the apps " +
                 "energyCommunityApp / voestApp and their profiles energy-community / voest-app. Without names it only lists what the " +
                 "built-in default has and the file lacks. An existing definition is kept unless overwrite=true. Persisted; applies to " +
                 "the next start.")]
    public DefaultsImport ImportDefaults(
        [Description("Who changes the config (logged).")] string owner,
        [Description("Built-in services to copy, e.g. ['voestApp'].")] List<string>? services = null,
        [Description("Built-in profiles to copy, e.g. ['voest-app'].")] List<string>? profiles = null,
        [Description("Replace definitions the file already has.")] bool overwrite = false,
        [Description(StackTools.SessionDescription)] string? session = null) =>
        ToolGuard.Run(() =>
        {
            var builtIn = ConfigStore.Parse(ConfigStore.ReadDefaultYaml(), "built-in default");
            var current = store.Load();
            var missingServices = builtIn.Services.Keys.Where(k => !current.Services.ContainsKey(k)).ToList();
            var missingProfiles = builtIn.Profiles.Keys.Where(k => !current.Profiles.ContainsKey(k)).ToList();
            services ??= [];
            profiles ??= [];
            if (services.Count == 0 && profiles.Count == 0)
            {
                return new DefaultsImport([], [], missingServices, missingProfiles, "Nothing imported; pass services and/or profiles.");
            }

            foreach (var name in services.Where(n => !builtIn.Services.ContainsKey(n)))
            {
                throw new ArgumentException($"The built-in default has no service '{name}'. It has: {string.Join(", ", builtIn.Services.Keys)}.");
            }

            foreach (var name in profiles.Where(n => !builtIn.Profiles.ContainsKey(n)))
            {
                throw new ArgumentException($"The built-in default has no profile '{name}'. It has: {string.Join(", ", builtIn.Profiles.Keys)}.");
            }

            var kept = services.Where(n => current.Services.ContainsKey(n) && !overwrite).Select(n => $"service {n}")
                .Concat(profiles.Where(n => current.Profiles.ContainsKey(n) && !overwrite).Select(n => $"profile {n}")).ToList();
            var importedServices = services.Where(n => overwrite || !current.Services.ContainsKey(n)).ToList();
            var importedProfiles = profiles.Where(n => overwrite || !current.Profiles.ContainsKey(n)).ToList();
            if (importedServices.Count + importedProfiles.Count > 0)
            {
                store.Update(c =>
                {
                    foreach (var name in importedServices)
                    {
                        c.Services[name] = builtIn.Services[name].Clone();
                    }

                    // A built-in startAfter names services the file may not have (identityServices); keep the ones it has.
                    foreach (var name in importedServices)
                    {
                        c.Services[name].StartAfter = c.Services[name].StartAfter.Where(c.Services.ContainsKey).ToList();
                    }

                    foreach (var name in importedProfiles)
                    {
                        c.Profiles[name] = builtIn.Profiles[name];
                    }
                });
                logger.LogInformation("{Owner} ({Session}) imported the built-in services {Services} and profiles {Profiles}", owner, session ?? "-",
                    string.Join(", ", importedServices),
                    string.Join(", ", importedProfiles));
            }

            return new DefaultsImport(importedServices, importedProfiles, missingServices.Except(importedServices).ToList(),
                missingProfiles.Except(importedProfiles).ToList(),
                kept.Count > 0 ? $"Kept as they are (pass overwrite=true to replace): {string.Join(", ", kept)}." : null);
        });

    [McpServerTool(Name = "admin_config_set_defaults")]
    [Description("Admin (the developer's go): changes the defaults of devstack.yaml - the base lane (defaultCheckout) and build configuration " +
                 "a stack starts from when none is given, and the stop timeout.")]
    public ConfigView SetDefaults(
        [Description("Who changes the config (logged).")] string owner,
        [Description("The base lane relative to rootPath, e.g. 'branches/main' (devstack.yaml defaultCheckout; overrides octo-tools' default lane).")]
        string? baseLane = null,
        [Description("Default configuration: DebugL, Release or Debug.")] string? configuration = null,
        [Description("Seconds between SIGTERM and SIGKILL (1-300).")] int? stopTimeoutSeconds = null,
        [Description(StackTools.SessionDescription)] string? session = null) =>
        ToolGuard.Run(() =>
        {
            var config = store.Update(c =>
            {
                if (baseLane != null)
                {
                    ServicePlanner.ResolveFolder(baseLane, ServicePlanner.RootPath(c), null, "base lane");
                    c.DefaultCheckout = baseLane;
                }

                if (configuration != null) c.Configuration = configuration;
                if (stopTimeoutSeconds != null) c.StopTimeoutSeconds = stopTimeoutSeconds.Value;
            });
            logger.LogInformation("{Owner} ({Session}) changed defaults", owner, session ?? "-");
            return View(config);
        });

    private ConfigView View(DevStackConfig c) => ViewOf(store.ConfigPath, c, store.WorkspaceInfo);

    /// <summary>
    ///     The configuration with secret-looking values masked (config_get and the status page's inspector), with the workspace
    ///     octo-tools describes and which of its values the file overrides (rootPath, defaultCheckout).
    /// </summary>
    internal static ConfigView ViewOf(string configPath, DevStackConfig c, WorkspaceInfo? workspace = null) => new(
        configPath,
        ServicePlanner.RootPath(c),
        ServicePlanner.OctoToolsPath(c),
        c.DefaultCheckout,
        c.Configuration,
        c.TargetFramework,
        c.LogDirectory,
        c.StopTimeoutSeconds,
        SecretMask.Mask(c.Environment),
        c.EnvProviders.Select(p => new EnvProviderView(p.Key, p.Value.Enabled, p.Value.WhenServices, p.Value.Script)).ToList(),
        c.Services.Select(s => ViewService(s.Key, s.Value)).ToList(),
        c.Profiles.Keys.ToList(),
        workspace,
        new[] { ("rootPath", c.RootPathSetting), ("defaultCheckout", c.DefaultCheckoutSetting) }
            .Where(o => o.Item2 != null).Select(o => o.Item1).ToList());

    internal static ServiceView ViewService(string name, ServiceConfig s) => new(
        name, s.Description, s.Repo, s.WorkingDirectory, s.Command, SecretMask.MaskArgs(s.Args), SecretMask.Mask(s.Env), SecretMask.Mask(s.Variables), SecretMask.Mask(s.AnnounceEnv), s.Ports,
        s.HealthUrl, s.Enabled, s.Optional, s.LogName ?? name, s.StartAfter);
}
