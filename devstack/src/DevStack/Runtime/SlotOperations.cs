using System.Net.Http.Json;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.Json.Serialization;
using Meshmakers.Octo.DevStack.Builds;
using Meshmakers.Octo.DevStack.Common;
using Meshmakers.Octo.DevStack.Configuration;

namespace Meshmakers.Octo.DevStack.Runtime;

/// <summary>The slot an env/slot argument means, with its derived values (shifted ports, data names) and where its local files go.</summary>
public sealed record SlotTarget(SlotInfo Slot, string? Environment, string LeaseOwner, string FilesFolder, DevStackConfig Shifted,
    IReadOnlyDictionary<string, string> Rows)
{
    /// <summary>The configured system database name of the slot (the services lowercase it, see <see cref="SlotCleanup.SystemDatabaseName"/>).</summary>
    public string SystemDatabase(DevStackConfig config) =>
        Rows.GetValueOrDefault("systemDatabase") ?? config.Environment.GetValueOrDefault("OCTO_SYSTEM__SYSTEMDATABASENAME") ?? "OctoSystem";

    /// <summary>A derived value by its slotDerivations row id (instancePrefix, streamDataSchema, ...), else the slot prefix.</summary>
    public string Row(string id) => Rows.GetValueOrDefault(id) ?? Slot.Prefix;
}

/// <summary>The admin step of stack_setup: what happened; the password is only in the owner-only file.</summary>
public sealed record BootstrapResult(
    string Slot,
    string Status,
    string Url,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    string? Email,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    string? CredentialsFile,
    string Note,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    string? SharedCredentialsFile = null,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    IReadOnlyList<string>? Warnings = null);

/// <summary>The octoCli step of stack_setup: the merged installation entry and the contexts registered.</summary>
public sealed record OctoCliRegistration(
    string Installation,
    string ConfigFile,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    string? Backup,
    bool Replaced,
    IReadOnlyList<string> Contexts,
    bool Success,
    IReadOnlyList<string> Notes,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    string? OutputTail);

/// <summary>service_env: the environment the daemon started a service with, secret values masked.</summary>
public sealed record ServiceEnvResult(string Service, string Slot, int Pid, string Source, IReadOnlyDictionary<string, string?> EnvVars, string Note);

/// <summary>
///     Bootstrap and verification of a stack slot (an environment's or a named one): the first admin of a fresh system
///     database, the octo-cli installation and contexts, the identity overlay, the effective environment of a service.
/// </summary>
public sealed partial class SlotOperations(ConfigStore store, StackSupervisor supervisor, IPwshRunner pwsh, HttpMessageHandler? http = null,
    string? octoToolsConfigFile = null, PreStartChecks? checks = null, Func<DevStackConfig, ISlotInventory>? inventory = null,
    Func<IEnumerable<(int Pid, int ParentPid)>>? processLinks = null, Func<string, string?>? sharedFileProtection = null)
{
    /// <summary>
    ///     stack_verify: the slot's derived data names against MongoDB (system database, tenant registry, ownership markers,
    ///     tenant databases registered in another slot's system database), RabbitMQ (queues and consumers with the slot's
    ///     prefix) and CrateDB (schemas). Read-only.
    /// </summary>
    public async Task<SlotVerifyResult> VerifyAsync(string? lane, string? slot, CancellationToken cancellationToken)
    {
        var config = store.Load();
        // Read-only: the default slot may be verified too (its data names come from the configuration, it derives nothing).
        var target = lane == null && slot == SlotInfo.DefaultName ? DefaultTarget(config) : Resolve(lane, slot);
        var all = new List<(string, string)>();
        var schemaPrefixes = new List<string>();
        foreach (var (info, _) in supervisor.Registry.Known().Where(k => k.Slot.Name != target.Slot.Name))
        {
            var other = info.IsDefault ? DefaultTarget(config) : TargetOf(config, info, null, "");
            all.Add((info.Name, other.SystemDatabase(config)));
            schemaPrefixes.Add(SlotCleanup.SchemaPrefix(other.Row("streamDataSchema")));
        }

        var recorded = supervisor.Registry.Known().Any(k => k.Slot.Name == target.Slot.Name)
            ? supervisor.Slot(target.Slot.Name).LiveServices().Select(s => (s.Service, s.Pid)).ToList()
            : [];
        // The broker sees the service process, the daemon recorded its launcher (cmd.exe on Windows): children count as the slot's own.
        var own = recorded.Count == 0 ? new Dictionary<int, string>() : SlotVerifier.OwnProcesses(recorded, (processLinks ?? ProcessTree.Links)());
        return await SlotVerifier.VerifyAsync(config, target, all, (inventory ?? (c => new LocalInfraInventory(c)))(config), cancellationToken, own,
            schemaPrefixes);
    }

    /// <summary>The default slot as a verify target: system database, broker and schema prefix as configured (services' defaults otherwise).</summary>
    private SlotTarget DefaultTarget(DevStackConfig config)
    {
        string? Configured(string suffix) =>
            config.Environment.FirstOrDefault(e => e.Key.EndsWith(suffix, StringComparison.Ordinal)).Value ??
            config.Services.Values.SelectMany(s => s.Env).FirstOrDefault(e => e.Key.EndsWith(suffix, StringComparison.Ordinal)).Value;

        var rows = new Dictionary<string, string>
        {
            ["systemDatabase"] = config.Environment.GetValueOrDefault("OCTO_SYSTEM__SYSTEMDATABASENAME") ?? "OctoSystem",
            // MassTransit's queue names start with "default-" when no instance prefix is configured.
            ["instancePrefix"] = Configured("__INSTANCEPREFIX") is { Length: > 0 } broker ? broker : "default",
            ["streamDataSchema"] = config.Environment.GetValueOrDefault("OCTO_STREAMDATA__SCHEMAINSTANCEPREFIX") ?? ""
        };
        return new SlotTarget(SlotInfo.Default, null, "", SlotDeriver.SlotDirectory(supervisor.StateDirectory, SlotInfo.Default), config, rows);
    }

    private SlotTarget TargetOf(DevStackConfig config, SlotInfo info, string? environment, string leaseOwner)
    {
        var slotDir = SlotDeriver.SlotDirectory(supervisor.StateDirectory, info);
        var derivation = SlotDeriver.Apply(ProfileResolver.Materialize(config, null, null), info, slotDir);
        return new SlotTarget(info, environment, leaseOwner, slotDir, derivation.Config,
            derivation.Rows.GroupBy(r => r.Id).ToDictionary(g => g.Key, g => g.First().Value));
    }

    public const string CredentialsFileName = "admin-credentials.json";

    private readonly HttpClient _http = new(http ?? new HttpClientHandler
    {
        // Local dev only: the services use the ASP.NET dev certificate, which the daemon need not trust.
        ServerCertificateCustomValidationCallback = HttpClientHandler.DangerousAcceptAnyServerCertificateValidator
    }) { Timeout = TimeSpan.FromSeconds(30) };

    /// <summary>The octo-tools config file (OCTO_TOOLS_CONFIG, else ~/.config/octo-tools/installations.json) - the same rule as Get-OctoToolsConfigPath.</summary>
    public string OctoToolsConfigFile => octoToolsConfigFile ?? System.Environment.GetEnvironmentVariable("OCTO_TOOLS_CONFIG") ??
        Path.Combine(System.Environment.GetFolderPath(System.Environment.SpecialFolder.UserProfile), ".config", "octo-tools", "installations.json");

    /// <summary>
    ///     lane or slot -&gt; the slot with its derived values. Files go to &lt;lane&gt;/.octo for a lane (octo-tools: feature
    ///     environment), else to the slot's state folder. The default slot is refused: it is the shared stack (installation 'local').
    /// </summary>
    public SlotTarget Resolve(string? lane, string? slot)
    {
        var config = store.Load();
        var scope = EnvironmentBinding.Resolve(config, lane, slot);
        var name = scope?.Slot ?? slot ?? throw new ArgumentException("Pass lane=<lane> or slot=<slot>.");
        if (name == SlotInfo.DefaultName)
        {
            throw new ArgumentException("stack_setup sets up lane stacks (and named slots); the shared stack (octo-tools installation 'local') is not set up by the daemon.");
        }

        SlotInfo info;
        try
        {
            info = supervisor.Registry.Resolve(name, create: false);
        }
        catch (InvalidOperationException) when (scope != null)
        {
            // An environment created outside the daemon: reserve its slot now (as lane_create does).
            info = supervisor.Registry.Resolve(name, create: true);
        }

        var slotDir = SlotDeriver.SlotDirectory(supervisor.StateDirectory, info);
        var derivation = SlotDeriver.Apply(ProfileResolver.Materialize(config, null, null), info, slotDir);
        var files = scope != null ? Path.Combine(scope.Checkout, ".octo") : slotDir;
        return new SlotTarget(info, scope?.Name, scope?.LeaseOwner ?? "", files, derivation.Config,
            derivation.Rows.GroupBy(r => r.Id).ToDictionary(g => g.Key, g => g.First().Value));
    }

    private void Claim(SlotTarget target, string owner)
    {
        if (string.IsNullOrWhiteSpace(owner))
        {
            throw new ArgumentException("owner is required.");
        }

        if (target.Environment != null)
        {
            EnvironmentBinding.Claim(supervisor, EnvironmentBinding.Resolve(store.Load(), target.Environment)!, owner);
        }
        else
        {
            supervisor.Leases.Get(target.Slot.Name).Require(owner);
        }
    }

    private static string SystemTenant(DevStackConfig config) =>
        config.Environment.GetValueOrDefault("OCTO_SYSTEM__SYSTEMTENANTID") is { Length: > 0 } tenant ? tenant : SlotArtifacts.SystemTenant;

    // ---------- first admin ----------

    /// <summary>
    ///     Creates the first admin of the slot's (empty) system database through the identity setup API
    ///     (POST /&lt;systemTenant&gt;/api/setup/create-admin). The password goes into an owner-only (600) file and is never
    ///     part of the result, a warning or an error; an existing credentials file is never overwritten. A lane stack takes
    ///     email and password from the shared admin file when it is there and usable (AB#9865, <see cref="SharedAdminFor"/>),
    ///     else the password is generated.
    /// </summary>
    internal async Task<BootstrapResult> BootstrapAdminAsync(string owner, string? lane, string? slot, string? email, CancellationToken cancellationToken)
    {
        var target = Resolve(lane, slot);
        Claim(target, owner);
        return await BootstrapAdminCoreAsync(target, email, cancellationToken);
    }

    internal async Task<BootstrapResult> BootstrapAdminCoreAsync(SlotTarget target, string? email, CancellationToken cancellationToken)
    {
        var config = store.Load();
        var port = SlotDeriver.Port(target.Shifted, "identityServices", "https");
        var tenant = SystemTenant(config);
        var url = $"https://localhost:{port}/{tenant}/api/setup/create-admin";
        var file = Path.Combine(target.FilesFolder, CredentialsFileName);
        if (File.Exists(file))
        {
            return new BootstrapResult(target.Slot.Name, "credentialsFileExists", url, null, file,
                "A credentials file exists already; nothing was sent. Delete it only if that admin is gone (a fresh system database).");
        }

        var warnings = new List<string>();
        var shared = SharedAdminFor(target, config, warnings);
        email ??= shared?.Email ?? $"admin@{target.Slot.Name}.local";
        var password = shared?.Password ?? GeneratePassword();
        Directory.CreateDirectory(target.FilesFolder);
        WriteOwnerOnly(file, JsonSerializer.Serialize(new { email, password, tenant, url, slot = target.Slot.Name, createdAt = DateTimeOffset.Now },
            new JsonSerializerOptions { WriteIndented = true }));
        HttpResponseMessage response;
        try
        {
            response = await _http.PostAsJsonAsync(url, new { email, password, confirmPassword = password }, cancellationToken);
        }
        catch (Exception e) when (e is HttpRequestException or TaskCanceledException)
        {
            File.Delete(file);
            throw new InvalidOperationException(
                $"The identity service of slot '{target.Slot.Name}' does not answer on {url} ({Hide(e.Message, password)}); start it first.");
        }

        using (response)
        {
            if (response.StatusCode == System.Net.HttpStatusCode.NotFound)
            {
                File.Delete(file);
                return new BootstrapResult(target.Slot.Name, "alreadySetUp", url, null, null,
                    "The system database has users already (the setup API answers 404 then); nothing was changed.", null, Warned(warnings));
            }

            var body = await response.Content.ReadAsStringAsync(cancellationToken);
            var ok = response.IsSuccessStatusCode && JsonNode.Parse(body) is JsonObject json && json["success"]?.GetValue<bool>() == true;
            if (!ok)
            {
                File.Delete(file);
                // The identity's own message names the broken password rule; the password is cut out before anything is passed on.
                throw new InvalidOperationException($"create-admin failed ({(int)response.StatusCode}): {Truncate(Hide(body, password), 300)}" +
                                                    (shared != null ? $" (password from the shared admin credentials file {shared.File})" : ""));
            }
        }

        return new BootstrapResult(target.Slot.Name, "created", url, email, file,
            $"Admin {email} created in the system tenant '{tenant}' of slot '{target.Slot.Name}'; the password is in {file} (owner-only)" +
            (shared != null ? $", taken from the shared admin credentials file {shared.File}." : "."), shared?.File, Warned(warnings));
    }

    private static IReadOnlyList<string>? Warned(List<string> warnings) => warnings.Count > 0 ? warnings : null;

    /// <summary>Cuts <paramref name="password"/> out of text that goes into an answer or an error (belt and braces: nothing should echo it).</summary>
    internal static string Hide(string text, string password) => password.Length == 0 ? text : text.Replace(password, "***", StringComparison.Ordinal);

    /// <summary>24 characters from a CSPRNG with upper, lower, digit and symbol (the identity password rules).</summary>
    internal static string GeneratePassword()
    {
        const string upper = "ABCDEFGHJKLMNPQRSTUVWXYZ", lower = "abcdefghijkmnopqrstuvwxyz", digits = "23456789", symbols = "!#%*+-=?@_";
        var all = upper + lower + digits + symbols;
        var chars = new List<char>
        {
            upper[RandomNumberGenerator.GetInt32(upper.Length)], lower[RandomNumberGenerator.GetInt32(lower.Length)],
            digits[RandomNumberGenerator.GetInt32(digits.Length)], symbols[RandomNumberGenerator.GetInt32(symbols.Length)]
        };
        while (chars.Count < 24)
        {
            chars.Add(all[RandomNumberGenerator.GetInt32(all.Length)]);
        }

        return new string(chars.OrderBy(_ => RandomNumberGenerator.GetInt32(int.MaxValue)).ToArray());
    }

    /// <summary>Creates the file readable and writable by its owner only (mode 600 on macOS/Linux).</summary>
    internal static void WriteOwnerOnly(string file, string content)
    {
        var options = new FileStreamOptions { Mode = FileMode.CreateNew, Access = FileAccess.Write };
        if (!OperatingSystem.IsWindows())
        {
            options.UnixCreateMode = UnixFileMode.UserRead | UnixFileMode.UserWrite;
        }

        using var stream = new FileStream(file, options);
        stream.Write(Encoding.UTF8.GetBytes(content));
    }

    private static string Truncate(string s, int n) => s.Length <= n ? s : s[..n] + " ...";

    // ---------- octo-cli ----------

    /// <summary>
    ///     Merges the slot's installation entry (local-&lt;slot&gt;, shifted URLs) into the octo-tools config file (backup first;
    ///     an entry of the same name is replaced) and registers octo-cli contexts for <paramref name="tenants"/> with
    ///     Register-OctoCliContext -NoSwitch, never changing the active context. login=false adds -NoLogin (the login is
    ///     interactive, device code).
    /// </summary>
    internal async Task<OctoCliRegistration> RegisterOctoCliAsync(string owner, string? lane, string? slot, IReadOnlyList<string> tenants, bool login,
        CancellationToken cancellationToken)
    {
        var target = Resolve(lane, slot);
        Claim(target, owner);
        return await RegisterOctoCliCoreAsync(target, tenants, login, cancellationToken);
    }

    private async Task<OctoCliRegistration> RegisterOctoCliCoreAsync(SlotTarget target, IReadOnlyList<string> tenants, bool login, CancellationToken cancellationToken)
    {
        var config = store.Load();
        var entry = SlotArtifacts.RenderInstallation(target.Shifted, target.Slot);
        var name = SlotArtifacts.InstallationName(target.Slot);
        var file = OctoToolsConfigFile;
        var (backup, replaced) = MergeInstallation(file, entry);
        var notes = new List<string>
        {
            $"{(replaced ? "Replaced" : "Added")} installation '{name}' in {file}{(backup != null ? $" (backup {backup})" : "")}."
        };
        if (tenants.Count == 0)
        {
            notes.Add($"No tenants given: register contexts later with {RepairCall(target.Environment, target.Slot.Name, SlotSetupSteps.OctoCli)[..^1]}, tenants=[...]) " +
                      $"or Register-OctoCliContext -Installation {name} -TenantId <t> -NoSwitch.");
            return new OctoCliRegistration(name, file, backup, replaced, [], true, notes, null);
        }

        var call = $"Register-OctoCliContext -Installation {PwshRunner.Quote(name)} -TenantId @({string.Join(",", tenants.Select(PwshRunner.Quote))}) -NoSwitch" +
                   (login ? "" : " -NoLogin") + " -Json";
        var result = await pwsh.RunAsync(ServicePlanner.OctoToolsPath(config), BuildPlanner.RootPrelude(ServicePlanner.RootPath(config)) + call,
            new PwshRunOptions { Timeout = TimeSpan.FromMinutes(login ? 10 : 2), Environment = new Dictionary<string, string?> { ["OCTO_TOOLS_CONFIG"] = file } },
            cancellationToken);
        var json = PwshRunner.ExtractOctoJson(result.Output, "Register-OctoCliContext");
        var success = result.ExitCode == 0 && json != null && BuildPlanner.Bool((json["data"] as JsonObject)?["success"]) != false;
        var contexts = tenants.Select(t => $"{name}_{t}").ToList();
        if (!login)
        {
            notes.Add($"Contexts registered without login; log in with Register-OctoCliContext -Installation {name} -TenantId {tenants[0]} -NoSwitch in a terminal " +
                      "(device code) or pass login=true.");
        }

        return new OctoCliRegistration(name, file, backup, replaced, contexts, success, notes, success ? null : PwshRunner.Tail(result.Output, 30));
    }

    /// <summary>
    ///     Held across every read-modify-replace of the octo-tools installations file (<see cref="MergeInstallation"/> of the
    ///     setups of all slots, the removal of a dropped slot's entry in <see cref="SlotDataStores"/>): two writers would
    ///     otherwise both read the old file, and the later replace would drop the other's entry.
    /// </summary>
    internal static readonly object InstallationsFileLock = new();

    /// <summary>
    ///     A backup name no earlier backup has (milliseconds, then a counter): two writes within one second must not overwrite
    ///     the first copy of the original file. Called under <see cref="InstallationsFileLock"/>.
    /// </summary>
    internal static string BackupName(string file)
    {
        var stem = $"{file}.bak-{DateTime.Now:yyyyMMddHHmmssfff}";
        var name = stem;
        for (var i = 2; File.Exists(name); i++)
        {
            name = $"{stem}-{i}";
        }

        return name;
    }

    /// <summary>Replaces or appends the installation (by name) in installations[]; a backup copy is written first. Returns (backup, replaced).</summary>
    internal static (string? Backup, bool Replaced) MergeInstallation(string file, JsonObject entry)
    {
        lock (InstallationsFileLock)
        {
            return MergeInstallationLocked(file, entry);
        }
    }

    private static (string? Backup, bool Replaced) MergeInstallationLocked(string file, JsonObject entry)
    {
        JsonObject root;
        string? backup = null;
        if (File.Exists(file))
        {
            root = JsonNode.Parse(Common.SharedFile.ReadAllText(file), documentOptions: new JsonDocumentOptions { CommentHandling = JsonCommentHandling.Skip }) as JsonObject
                   ?? throw new InvalidOperationException($"{file} is not a JSON object; nothing was changed.");
            backup = BackupName(file);
            File.Copy(file, backup, overwrite: false);
        }
        else
        {
            Directory.CreateDirectory(Path.GetDirectoryName(file)!);
            root = new JsonObject();
        }

        var list = root["installations"] as JsonArray ?? new JsonArray();
        root["installations"] = list;
        var name = entry["name"]?.GetValue<string>();
        var index = list.Select((n, i) => (n, i)).FirstOrDefault(x => x.n?["name"]?.GetValue<string>() == name).i;
        var replaced = list.Count > 0 && list[index]?["name"]?.GetValue<string>() == name;
        if (replaced)
        {
            list[index] = entry.DeepClone();
        }
        else
        {
            list.Add(entry.DeepClone());
        }

        var temp = file + ".tmp";
        File.WriteAllText(temp, root.ToJsonString(new JsonSerializerOptions { WriteIndented = true }));
        if (!OperatingSystem.IsWindows() && File.Exists(file))
        {
            File.SetUnixFileMode(temp, File.GetUnixFileMode(file));
        }

        Common.SharedFile.Replace(temp, file);
        return (backup, replaced);
    }

    // ---------- identity overlay ----------

    /// <summary>Writes the slot's identity overlay and applies it once through the context local-&lt;slot&gt;_&lt;system tenant&gt;.</summary>
    internal async Task<EnvironmentCommandResult> ApplyOverlayAsync(string owner, string? lane, string? slot, CancellationToken cancellationToken)
    {
        var target = Resolve(lane, slot);
        Claim(target, owner);
        return await ApplyOverlayCoreAsync(target, cancellationToken);
    }

    /// <param name="loggedIn">
    ///     The tenants the calling setup logged in: a tenant's own overlay is applied only for them (null: every tenant with an
    ///     octo-cli context, as stack_setup(steps=["overlay"]) alone does).
    /// </param>
    private async Task<EnvironmentCommandResult> ApplyOverlayCoreAsync(SlotTarget target, CancellationToken cancellationToken, IReadOnlyCollection<string>? loggedIn = null)
    {
        var config = store.Load();
        var context = $"{SlotArtifacts.InstallationName(target.Slot)}_{SystemTenant(config)}";
        if ((checks ?? new PreStartChecks()).HasOctoCliContext(context) != true)
        {
            throw new InvalidOperationException($"There is no octo-cli context {context} yet; {RepairCall(target.Environment, target.Slot.Name, null)} " +
                                                "registers and logs it in.");
        }

        // Only the clients of the services the slot runs: a configured service it does not run (an app of another profile) has no
        // client in the slot's identity server, and octo-cli would fail on it. A slot that runs nothing keeps every client.
        var paths = SlotArtifacts.Write(target.Shifted, target.Slot, SlotDeriver.SlotDirectory(supervisor.StateDirectory, target.Slot),
            supervisor.Slot(target.Slot.Name).RunningServices());
        var octoTools = ServicePlanner.OctoToolsPath(config);
        var call = SlotArtifacts.ApplyCommand(target.Slot, paths.IdentityOverlay) + " -Json";
        var result = await pwsh.RunAsync(octoTools, call, new PwshRunOptions { Timeout = TimeSpan.FromMinutes(3) }, cancellationToken);
        var json = PwshRunner.ExtractOctoJson(result.Output);
        var failed = json?["data"]?["summary"]?["failed"]?.GetValue<int>();
        var success = result.ExitCode == 0 && failed is 0 or null && json != null;
        // AB#9676: the note says what failed - the exit code, the failed clients, or the missing result - never "failed (exit 0)" alone.
        var notes = new List<string>
        {
            success
                ? $"Overlay {paths.IdentityOverlay} through {context}."
                : $"Overlay {paths.IdentityOverlay} through {context} FAILED (" +
                  (result.ExitCode != 0 ? $"exit {result.ExitCode}" : failed is > 0 ? $"{failed} client(s) failed" : "Invoke-IdentityOverlay gave no JSON result") +
                  $"): {OverlayFailure(json, result.Output)}"
        };
        // The clients that apps keep in their own tenant: one overlay per tenant, through that tenant's context.
        foreach (var (tenant, file) in paths.TenantOverlays ?? new Dictionary<string, string>())
        {
            var tenantContext = $"{SlotArtifacts.InstallationName(target.Slot)}_{tenant}";
            if (loggedIn != null && !loggedIn.Contains(tenant, StringComparer.OrdinalIgnoreCase))
            {
                notes.Add($"Overlay {file} of tenant '{tenant}' was not applied: this setup did not log in tenant '{tenant}' (a fresh stack has only the " +
                          $"system tenant). Once the tenant exists, {RepairCall(target.Environment, target.Slot.Name, null)[..^1]}, tenants=[\"{tenant}\"]) applies it.");
                continue;
            }

            if ((checks ?? new PreStartChecks()).HasOctoCliContext(tenantContext) != true)
            {
                notes.Add($"Overlay {file} of tenant '{tenant}' was not applied: there is no octo-cli context {tenantContext} " +
                          $"({RepairCall(target.Environment, target.Slot.Name, null)[..^1]}, tenants=[\"{tenant}\"]) creates and logs it in).");
                continue;
            }

            var tenantResult = await pwsh.RunAsync(octoTools, SlotArtifacts.ApplyCommand(target.Slot, file, tenant) + " -Json",
                new PwshRunOptions { Timeout = TimeSpan.FromMinutes(3) }, cancellationToken);
            var tenantJson = PwshRunner.ExtractOctoJson(tenantResult.Output);
            var tenantFailed = tenantJson?["data"]?["summary"]?["failed"]?.GetValue<int>();
            var ok = tenantResult.ExitCode == 0 && tenantFailed is 0 or null;
            success &= ok;
            notes.Add(ok
                ? $"Overlay {file} through {tenantContext}."
                : $"Overlay {file} through {tenantContext} FAILED ({(tenantResult.ExitCode != 0 ? $"exit {tenantResult.ExitCode}" : $"{tenantFailed} client(s) failed")}): " +
                  $"{OverlayFailure(tenantJson, tenantResult.Output)}");
        }

        return new EnvironmentCommandResult(success, result.ExitCode, call, null, json?["data"]?.DeepClone(), notes,
            success ? null : PwshRunner.Tail(result.Output, 30));
    }

    /// <summary>
    ///     What failed in an Invoke-IdentityOverlay run: the failed clients of its JSON result by id and status. Its JSON result
    ///     does not carry octo-cli's own message (Invoke-IdentityOverlay without -Json prints it); without a result the error
    ///     of the output.
    /// </summary>
    private static string OverlayFailure(JsonObject? json, string output)
    {
        if (json == null)
        {
            return PwshErrors.Summary(output);
        }

        var failed = (json["data"]?["clients"] as JsonArray ?? [])
            .Select(c => (Client: c?["client"]?.GetValue<string>(), Status: c?["status"]?.GetValue<string>()))
            .Where(c => c.Status?.StartsWith("failed", StringComparison.Ordinal) == true)
            .Select(c => $"client {c.Client ?? "(no id)"} {c.Status}")
            .ToList();
        return failed.Count > 0
            ? string.Join("; ", failed) + " (octo-cli's message: Invoke-IdentityOverlay without -Json prints it)"
            : "the result names no failed client";
    }

    // ---------- service environment ----------

    /// <summary>
    ///     The environment a service of the slot was started with (on top of the daemon's own), secret-looking values masked.
    ///     After a daemon restart the launch environment is gone; on Linux it is then read from /proc/&lt;pid&gt;/environ.
    /// </summary>
    public ServiceEnvResult ServiceEnv(string? lane, string? slot, string service)
    {
        var name = lane != null || slot != null && slot != SlotInfo.DefaultName ? Resolve(lane, slot).Slot.Name : SlotInfo.DefaultName;
        var run = supervisor.Slot(name);
        var (pid, launch) = run.EnvOf(service) ?? throw new InvalidOperationException($"Service '{service}' does not run in slot '{name}'.");
        if (launch.Count > 0)
        {
            return new ServiceEnvResult(service, name, pid, "launch", Masked(launch), "The variables octo-devstack set; the rest comes from the daemon's environment.");
        }

        if (OperatingSystem.IsLinux() && ReadProcEnviron(pid) is { } process)
        {
            return new ServiceEnvResult(service, name, pid, "process", Masked(process), "Read from /proc (the service was adopted after a daemon restart).");
        }

        if (OperatingSystem.IsMacOS() &&
            ParsePsEnvironment(ProcessTree.RunTool("ps", $"eww -o command= -p {pid}"), ProcessTree.RunTool("ps", $"-ww -o command= -p {pid}")) is { Count: > 0 } ps)
        {
            return new ServiceEnvResult(service, name, pid, "process",
                Masked(ps), "Read with ps eww (the service was adopted after a daemon restart; the whole process environment, including the daemon's).");
        }

        return new ServiceEnvResult(service, name, pid, "unknown", new Dictionary<string, string?>(),
            "Adopted after a daemon restart: its launch environment is not known, and this OS does not expose another process's environment. " +
            "service_restart starts it again with a known one.");
    }

    private static SortedDictionary<string, string?> Masked(IEnumerable<KeyValuePair<string, string?>> env) =>
        new(SecretMask.MaskNullable(env), StringComparer.Ordinal);

    internal static Dictionary<string, string?>? ReadProcEnviron(int pid)
    {
        try
        {
            return ParseEnviron(File.ReadAllText($"/proc/{pid}/environ"));
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            return null;
        }
    }

    /// <summary>
    ///     macOS: ps eww prints the command line followed by the environment as NAME=value words. The plain command line
    ///     (ps -o command=) is cut off first; the rest splits before every " NAME=" (a value that itself contains " X=" is
    ///     split there too - the parts still get masked by their names).
    /// </summary>
    internal static Dictionary<string, string?> ParsePsEnvironment(string withEnvironment, string commandLine)
    {
        var all = withEnvironment.TrimEnd('\n', '\r');
        var command = commandLine.Trim();
        if (command.Length == 0 || !all.StartsWith(command, StringComparison.Ordinal))
        {
            return [];
        }

        var rest = all[command.Length..];
        var result = new Dictionary<string, string?>(StringComparer.Ordinal);
        foreach (var part in System.Text.RegularExpressions.Regex.Split(rest, @" (?=[A-Za-z_][A-Za-z0-9_]*=)"))
        {
            var equals = part.IndexOf('=');
            if (equals > 0)
            {
                result[part[..equals].Trim()] = part[(equals + 1)..];
            }
        }

        return result;
    }

    internal static Dictionary<string, string?> ParseEnviron(string text) =>
        text.Split('\0', StringSplitOptions.RemoveEmptyEntries)
            .Select(e => e.Split('=', 2))
            .Where(p => p.Length == 2 && p[0].Length > 0)
            .GroupBy(p => p[0]).ToDictionary(g => g.Key, g => (string?)g.Last()[1]);
}
