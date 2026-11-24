using System.Diagnostics;
using System.Text.Json;
using System.Text.Json.Serialization;
using Meshmakers.Octo.DevStack.Configuration;

namespace Meshmakers.Octo.DevStack.Runtime;

/// <summary>One requirement of a working machine: ok, warn (works with less), fail (does not work), info.</summary>
public sealed record SetupItem(
    string Name,
    string State,
    string Detail,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    string? Fix);

/// <summary>What a developer on a new machine still has to set up (setup_check, AB#9377). Ok: nothing fails.</summary>
public sealed record SetupReport(bool Ok, IReadOnlyList<SetupItem> Items);

/// <summary>What the check asks the machine; tests pass canned answers.</summary>
public sealed record SetupProbes(
    Func<string, string, (int ExitCode, string Output)?> Run,
    Func<string, bool> OnPath,
    Func<string, bool> FileExists,
    Func<Task<List<string>>> UnreachableInfra,
    Func<DockerVmInfo?> Docker,
    string Platform,
    string Home,
    Func<string, IReadOnlyList<string>, Task<BuildVariablesSeen?>>? BuildVariables = null,
    Func<string, string?>? Which = null);

/// <summary>
///     Which of the asked names a pwsh with the octo-tools profile has set - the environment of the daemon's builds - and
///     the private profile that profile.ps1 loads (octo-tools' own value). Never a value.
/// </summary>
public sealed record BuildVariablesSeen(IReadOnlyList<string> Set, string? PrivateProfile);

/// <summary>
///     Checks the requirements README "Install and run" names, each with the command that fixes it. Read-only: it runs
///     only <c>dotnet --list-sdks</c>, <c>dotnet dev-certs https --check --trust</c> and, when the default lane has a
///     repository that needs a build variable, a pwsh with the octo-tools profile that names the variables it has set
///     (never their values), probes the kind ports, looks for octo-cli on the daemon's own PATH and reads
///     the workspace the daemon got from octo-tools at its start. Claude Code's registration is read from ~/.claude.json
///     (only whether an octo-devstack entry exists).
/// </summary>
public sealed class SetupCheck(ConfigStore store, SetupProbes probes, Func<PersistedState>? state = null)
{
    public static SetupProbes MachineProbes(PreStartChecks checks, DockerVm docker) => new(
        RunTool,
        OnPath,
        File.Exists,
        () => checks.UnreachableInfraAsync(),
        () =>
        {
            try
            {
                return docker.Current();
            }
            catch (Exception e) when (e is InvalidOperationException or IOException or System.ComponentModel.Win32Exception)
            {
                return null;
            }
        },
        OperatingSystem.IsWindows() ? "windows" : OperatingSystem.IsMacOS() ? "macos" : "linux",
        Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
        ProbeBuildVariablesAsync,
        program => ResolveOnPath(program, Environment.GetEnvironmentVariable("PATH"), Environment.GetEnvironmentVariable("PATHEXT"), OperatingSystem.IsWindows(),
            File.Exists));

    internal const string OctoCliItem = "octo-cli on the daemon's PATH";

    /// <summary>
    ///     Where <paramref name="program"/> resolves on <paramref name="path"/> - the daemon's own PATH, not the caller's - as a
    ///     shell would find it (Windows: with the extensions of PATHEXT and .ps1, which pwsh runs too); null when it does not.
    /// </summary>
    internal static string? ResolveOnPath(string program, string? path, string? pathExt, bool windows, Func<string, bool> exists)
    {
        var separator = windows ? ';' : ':';
        var extensions = windows
            ? new[] { "" }.Concat((pathExt is { Length: > 0 } ? pathExt : ".COM;.EXE;.BAT;.CMD").Split(';', StringSplitOptions.RemoveEmptyEntries)).Append(".ps1")
                .Distinct(StringComparer.OrdinalIgnoreCase).ToList()
            : [""];
        foreach (var dir in (path ?? "").Split(separator, StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries))
        {
            foreach (var extension in extensions)
            {
                var candidate = Path.Combine(dir.Trim('"'), program + extension.ToLowerInvariant());
                if (exists(candidate))
                {
                    return candidate;
                }
            }
        }

        return null;
    }

    /// <summary>The body that asks a pwsh with the octo-tools profile which of <paramref name="names"/> it has set (names only).</summary>
    internal static string BuildVariablesBody(IReadOnlyList<string> names) =>
        $"$__names = @({string.Join(", ", names.Select(Common.PwshRunner.Quote))})\n" +
        $"Write-Output ('{Common.PwshRunner.Marker}' + ([ordered]@{{ set = @($__names | Where-Object {{ [Environment]::GetEnvironmentVariable($_) }}); " +
        "profile = $privateProfilePath } | ConvertTo-Json -Compress))";

    private static async Task<BuildVariablesSeen?> ProbeBuildVariablesAsync(string octoToolsPath, IReadOnlyList<string> names)
    {
        if (!Directory.Exists(octoToolsPath))
        {
            return null;
        }

        try
        {
            var result = await Common.PwshRunner.RunAsync(octoToolsPath, BuildVariablesBody(names), null, TimeSpan.FromMinutes(1), CancellationToken.None);
            return Common.PwshRunner.ExtractMarker(result.Output) is { } seen
                ? new BuildVariablesSeen((seen["set"] as System.Text.Json.Nodes.JsonArray ?? []).Select(n => n?.ToString() ?? "").Where(n => n.Length > 0).ToList(),
                    seen["profile"]?.ToString())
                : null;
        }
        catch (Exception e) when (e is System.ComponentModel.Win32Exception or InvalidOperationException or JsonException)
        {
            return null;
        }
    }

    /// <summary>
    ///     The line to put into the private profile: <c>$env:NAME = '&lt;value&gt;'</c> for a plain name, else (a name
    ///     <c>$env:</c> cannot spell, e.g. with an apostrophe) a SetEnvironmentVariable call with the name quoted.
    /// </summary>
    internal static string ProfileAssignment(string name) =>
        System.Text.RegularExpressions.Regex.IsMatch(name, "^[A-Za-z_][A-Za-z0-9_]*$")
            ? $"$env:{name} = '<value>'"
            : $"[Environment]::SetEnvironmentVariable({Common.PwshRunner.Quote(name)}, '<value>')";

    /// <summary>The built-in build variables of devstack.default.yaml with the file's: same name, the file's; others are added.</summary>
    internal static IReadOnlyList<BuildVariable> EffectiveBuildVariables(DevStackConfig config)
    {
        var builtIn = ConfigStore.BuiltIn.BuildVariables;
        return builtIn.Select(b => config.BuildVariables.FirstOrDefault(u => u.Name == b.Name) ?? b)
            .Concat(config.BuildVariables.Where(u => builtIn.All(b => b.Name != u.Name)))
            .Where(v => v.Name.Length > 0).ToList();
    }

    /// <summary>
    ///     AB#9464: the build variables a repository of the default lane needs, as the daemon's builds see them - a pwsh with
    ///     the octo-tools profile, which loads the private profile. None needed (or the base lane unknown, which the base lane item
    ///     names): no item.
    /// </summary>
    private async Task<SetupItem?> BuildVariablesItemAsync(DevStackConfig config)
    {
        string lane;
        try
        {
            lane = ServicePlanner.CreateContext(config, null, null).Checkout;
        }
        catch (InvalidOperationException)
        {
            return null;
        }

        var needed = EffectiveBuildVariables(config)
            .Select(v => (Variable: v, Repos: v.Repos.Where(r => Directory.Exists(Path.Combine(lane, r))).ToList()))
            .Where(x => x.Variable.Repos.Count == 0 || x.Repos.Count > 0).ToList();
        if (needed.Count == 0 || probes.BuildVariables == null)
        {
            return null;
        }

        var names = needed.Select(x => x.Variable.Name).ToList();
        var seen = await probes.BuildVariables(ServicePlanner.OctoToolsPath(config), names);
        if (seen == null)
        {
            return new SetupItem("build variables", "info", $"not checked ({string.Join(", ", names)}): pwsh with the octo-tools profile did not answer", null);
        }

        var missing = needed.Where(x => !seen.Set.Contains(x.Variable.Name, StringComparer.Ordinal)).ToList();
        if (missing.Count == 0)
        {
            return new SetupItem("build variables", "ok", $"{string.Join(", ", names)} set for the daemon's builds", null);
        }

        var detail = string.Join("; ", missing.Select(x =>
            $"{x.Variable.Name} is not set for the daemon's builds{(x.Variable.Why is { Length: > 0 } why ? $": {why}" : "")}" +
            (x.Repos.Count > 0 ? $" ({string.Join(", ", x.Repos)} fail without it)" : "")));
        var profile = seen.PrivateProfile is { Length: > 0 } p ? p : "your private PowerShell profile (octo-tools' profile.ps1 names it when it loads it)";
        var assignments = string.Join("; ", missing.Select(x => ProfileAssignment(x.Variable.Name)));
        return new SetupItem("build variables", "warn", detail,
            $"add {assignments} to {profile}: octo-tools' profile.ps1 loads it for every build of the daemon (a LaunchAgent, systemd unit or " +
            "logon task does not read ~/.zshrc or ~/.bashrc); then run setup_check again - no daemon restart needed");
    }

    public async Task<SetupReport> RunAsync()
    {
        var items = new List<SetupItem>();
        var workspace = store.WorkspaceInfo;
        var config = store.Load();
        var url = config.Server.Url.TrimEnd('/');

        items.Add(workspace?.Source switch
        {
            "octo-tools" => new SetupItem("octo-tools", "ok", $"{workspace.ToolsPath} describes the workspace", null),
            "unanswered" => new SetupItem("octo-tools", "fail", string.Join(" ", workspace.Problems),
                workspace.Problems.Any(p => p.Contains("newer octo-tools", StringComparison.Ordinal))
                    ? $"git pull in {workspace.ToolsPath} (Get-OctoWorkspace) and make sure pwsh runs, then restart the daemon"
                    : $"run pwsh -Command \". {Common.PwshRunner.Quote(Path.Combine(workspace.ToolsPath ?? "octo-tools", "modules", "profile.ps1"))}; Get-OctoWorkspace -Json\" to see what fails, fix it, then restart the daemon"),
            _ => new SetupItem("octo-tools", "fail", workspace?.Problems.FirstOrDefault() ?? "octo-tools was not found",
                "run the daemon from the devstack folder of an octo-tools checkout (Start-OctoDevStackDaemon), or set OCTO_TOOLS_PATH")
        });

        const string laneFix = "clone the repositories (Invoke-CloneMainRepos) into the octo-tools root or branches/main, or set $env:OCTO_ENVIRONMENT_BASE";
        var problems = ServicePlanner.FolderProblems(config, store.ConfigPath);
        if (problems.Count > 0)
        {
            items.Add(new SetupItem("base lane", "fail", string.Join(" ", problems), laneFix));
        }
        else
        {
            try
            {
                items.Add(new SetupItem("base lane", "ok", $"{ServicePlanner.CreateContext(config, null, null).Checkout} ({workspace?.Layout ?? "?"} layout)", null));
            }
            catch (InvalidOperationException e)
            {
                // A folder that exists but is no usable lane (an environment folder with a problem, no default lane): the
                // report goes on with the other checks.
                items.Add(new SetupItem("base lane", "fail", e.Message, laneFix));
            }
        }

        if (await BuildVariablesItemAsync(config) is { } buildVariables)
        {
            items.Add(buildVariables);
        }

        // Looked at now, not taken from the workspace of the daemon's start: the file may have been created meanwhile.
        var installations = workspace?.ConfigDirectory is { Length: > 0 } configDirectory ? Path.Combine(configDirectory, "installations.json") : null;
        items.Add(installations == null
            ? new SetupItem("installations.json", "info", "unknown: octo-tools did not describe the workspace", null)
            : probes.FileExists(installations)
                ? new SetupItem("installations.json", "ok", $"in {workspace!.ConfigDirectory}", null)
                : new SetupItem("installations.json", "warn", $"no octo-tools config in {workspace!.ConfigDirectory}: octo-cli contexts and slot logins cannot be registered",
                    $"copy installations.example.json from {workspace.ToolsPath} to {workspace.ConfigDirectory}/installations.json and edit it"));

        items.Add(workspace?.Source == "octo-tools" || probes.OnPath("pwsh")
            ? new SetupItem("pwsh", "ok", "PowerShell 7 runs the octo-tools cmdlets", null)
            : new SetupItem("pwsh", "fail", "pwsh is not on PATH: builds, env providers and lanes need it", "install PowerShell 7"));

        var sdks = probes.Run("dotnet", "--list-sdks");
        items.Add(sdks is { ExitCode: 0 } s && s.Output.Split('\n').Any(l => l.TrimStart().StartsWith("10.", StringComparison.Ordinal))
            ? new SetupItem(".NET SDK", "ok", "a .NET 10 SDK is installed", null)
            : new SetupItem(".NET SDK", "fail", "no .NET 10 SDK (dotnet --list-sdks)", "install the .NET 10 SDK"));

        items.Add(probes.Platform switch
        {
            "windows" => new SetupItem("process tools", "ok", "Toolhelp snapshot and TCP table (built into Windows)", null),
            "linux" when !probes.OnPath("lsof") => new SetupItem("process tools", "info", "lsof is not installed: ports and processes are read from /proc", null),
            _ when probes.OnPath("lsof") => new SetupItem("process tools", "ok", "lsof and ps", null),
            _ => new SetupItem("process tools", "fail", "lsof is not installed: ports in use and foreign processes go unseen", "install lsof")
        });

        var cert = probes.Run("dotnet", "dev-certs https --check --trust");
        items.Add(cert is { ExitCode: 0 }
            ? new SetupItem("dev certificate", "ok", "the ASP.NET development certificate is trusted", null)
            : new SetupItem("dev certificate", probes.Platform == "linux" ? "info" : "warn",
                "the ASP.NET development certificate is missing or not trusted: the services listen on https://localhost",
                probes.Platform == "linux" ? "dotnet dev-certs https (trust it in your browser and system store)" : "dotnet dev-certs https --trust"));

        var docker = probes.Docker();
        items.Add(docker is { Available: true }
            ? new SetupItem("Docker", docker.Warning == null ? "ok" : "warn",
                $"{docker.MemoryGb:0.#} GiB, {docker.Cpus} CPUs{(docker.Kind ? ", kind cluster running" : "")}{(docker.Warning is { } w ? ": " + w : "")}", null)
            : new SetupItem("Docker", "warn", "docker does not answer: no kind cluster, no test containers", "start Docker (Docker Desktop on Windows/macOS)"));

        if (state != null)
        {
            // AB#9555: checkout and repository paths on record that no longer exist (a moved checkout).
            items.Add(StalePaths.Item(StalePaths.Find(config, state())));
        }

        var unreachable = await probes.UnreachableInfra();
        items.Add(unreachable.Count == 0
            ? new SetupItem("kind infrastructure", "ok", "MongoDB, RabbitMQ and CrateDB answer", null)
            : new SetupItem("kind infrastructure", "warn", $"not reachable: {string.Join(", ", unreachable)}", "Install-OctoKubernetes (first time), else start Docker"));

        if (probes.Which != null)
        {
            items.Add(probes.Which("octo-cli") is { } octoCli
                ? new SetupItem(OctoCliItem, "ok", $"{octoCli} (the lane stack setup and Register-OctoCliContext run it)", null)
                : new SetupItem(OctoCliItem, "warn",
                    "octo-cli does not resolve on the PATH the daemon runs with (its own process environment, not your shell's): the setup of a lane stack " +
                    "(octo-cli contexts, login) and Register-OctoCliContext fail with \"The term 'octo-cli' is not recognized\". A daemon keeps the PATH of " +
                    "the shell it was started from, also one from before octo-cli's folder moved (a workspace move)",
                    "open a new shell (it reads the current PATH; Get-Command octo-cli shows where octo-cli is) and restart the daemon from it with " +
                    "Start-OctoDevStackDaemon -Restart - when daemon_status says restart.safe is true or the developer says so; then stack_setup(owner, lane)"));
        }

        var contexts = Path.Combine(Environment.GetEnvironmentVariable("OCTO_CLI_HOME") is { Length: > 0 } cliHome ? cliHome : probes.Home, ".octo-cli", "contexts.json");
        items.Add(probes.FileExists(contexts)
            ? new SetupItem("octo-cli", "ok", "octo-cli has contexts", null)
            : new SetupItem("octo-cli", "warn", "octo-cli has no contexts: tenants of a stack cannot be logged in to", "Register-OctoCliContext -Installation local"));

        items.Add(ClaudeRegistered(Path.Combine(probes.Home, ".claude.json"), url) is true
            ? new SetupItem("Claude Code", "ok", "octo-devstack is registered as an MCP server", null)
            : new SetupItem("Claude Code", "info", "octo-devstack is not registered for all Claude Code sessions (user scope)",
                $"claude mcp add --transport http --scope user octo-devstack {url}/mcp"));

        return new SetupReport(items.All(i => i.State != "fail"), items);
    }

    /// <summary>Whether ~/.claude.json has a user-scope MCP server named octo-devstack; null when unreadable. Reads names only.</summary>
    internal static bool? ClaudeRegistered(string file, string url)
    {
        try
        {
            if (!File.Exists(file))
            {
                return null;
            }

            using var document = JsonDocument.Parse(Common.SharedFile.ReadAllText(file));
            if (document.RootElement.ValueKind != JsonValueKind.Object)
            {
                return null; // null, an array or a value: not a Claude Code settings file
            }

            return document.RootElement.TryGetProperty("mcpServers", out var servers) && servers.ValueKind == JsonValueKind.Object &&
                   servers.EnumerateObject().Any(s => s.Name == "octo-devstack");
        }
        catch (Exception e) when (e is IOException or JsonException or UnauthorizedAccessException)
        {
            return null;
        }
    }

    private static (int ExitCode, string Output)? RunTool(string file, string arguments)
    {
        try
        {
            using var process = Process.Start(new ProcessStartInfo(file, arguments)
            {
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                UseShellExecute = false,
                CreateNoWindow = true
            });
            if (process == null)
            {
                return null;
            }

            var output = process.StandardOutput.ReadToEndAsync();
            _ = process.StandardError.ReadToEndAsync();
            if (!process.WaitForExit(30_000))
            {
                process.Kill(entireProcessTree: true);
                return null;
            }

            return (process.ExitCode, output.Result);
        }
        catch (Exception e) when (e is System.ComponentModel.Win32Exception or InvalidOperationException)
        {
            return null;
        }
    }

    private static bool OnPath(string program) =>
        (Environment.GetEnvironmentVariable("PATH") ?? "").Split(Path.PathSeparator, StringSplitOptions.RemoveEmptyEntries)
        .Any(dir => File.Exists(Path.Combine(dir, program)) || (OperatingSystem.IsWindows() && File.Exists(Path.Combine(dir, program + ".exe"))));
}
