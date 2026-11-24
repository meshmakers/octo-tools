using System.Reflection;
using System.Text.Json;
using System.Text.Json.Nodes;
using Meshmakers.Octo.DevStack.Common;
using Meshmakers.Octo.DevStack.Configuration;

namespace Meshmakers.Octo.DevStack.Runtime;

public sealed record SlotAfterStart(IReadOnlyList<string> Notes, IReadOnlyList<string> Warnings);

/// <summary>Paths of the files octo-devstack generates for a slot (in the state folder, never in a repository).</summary>
public sealed record SlotArtifactPaths(string Directory, string IdentityOverlay, string Installation)
{
    /// <summary>Overlays of clients that live in another tenant than the system tenant (apps), keyed by tenant.</summary>
    [System.Text.Json.Serialization.JsonIgnore(Condition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull)]
    public IReadOnlyDictionary<string, string>? TenantOverlays { get; init; }
}

/// <summary>
///     What happens around the start of a non-default slot: the identity overlay with the slot's redirect URIs and an octo-cli
///     installation entry with its service URLs (both files in &lt;state&gt;/slots/&lt;name&gt;/), and a smoke check of the
///     identity issuer. The setup (stack_setup, run by itself after the start) registers the entry and applies the overlay.
/// </summary>
public sealed class SlotArtifacts
{
    /// <summary>The tenant whose octo-cli context applies the overlay (the clients live in the system tenant).</summary>
    public const string SystemTenant = "octosystem";

    /// <summary>The identity service: a slot is set up once it is healthy, and the overlay and the smoke check are about it.</summary>
    public const string IdentityService = "identityServices";

    private static readonly HttpClient Http = new(new HttpClientHandler
    {
        // Local dev only: the services use the ASP.NET dev certificate.
        ServerCertificateCustomValidationCallback = HttpClientHandler.DangerousAcceptAnyServerCertificateValidator
    }) { Timeout = TimeSpan.FromSeconds(5) };

    /// <summary>The installation name of a slot in ~/.config/octo-tools/installations.json: local-&lt;slot&gt;.</summary>
    public static string InstallationName(SlotInfo slot) => $"local-{slot.Name}";

    public static SlotArtifactPaths PathsOf(string slotDirectory) =>
        new(slotDirectory, Path.Combine(slotDirectory, "identity-overlay.yaml"), Path.Combine(slotDirectory, "octo-tools-installation.json"));

    public static string InstallationFile(SlotRun run) => PathsOf(run.SlotDirectory).Installation;

    public static string ReadOverlayTemplate()
    {
        using var stream = Assembly.GetExecutingAssembly().GetManifestResourceStream("identity-overlay.template.yaml")
                           ?? throw new InvalidOperationException("Embedded identity-overlay.template.yaml is missing.");
        using var reader = new StreamReader(stream);
        return reader.ReadToEnd();
    }

    /// <summary>
    ///     The slot's identity overlay: the template with the slot's shifted ports (<paramref name="shifted"/> is the slot's
    ///     configuration), plus the clients of the configured services that live in the system tenant.
    ///     <paramref name="services"/>: only the clients of these services (the ones the slot runs); null: of every service.
    /// </summary>
    public static string RenderOverlay(DevStackConfig shifted, SlotInfo slot, string slotDirectory, IReadOnlyCollection<string>? services = null) =>
        SlotDeriver.Render(ReadOverlayTemplate(), shifted, slot, slotDirectory).TrimEnd('\n') + "\n" + SystemClientsYaml(shifted, slot, slotDirectory, services);

    private static string SystemClientsYaml(DevStackConfig shifted, SlotInfo slot, string slotDirectory, IReadOnlyCollection<string>? services) =>
        ClientsYaml(shifted, slot, slotDirectory, services,
            c => string.IsNullOrWhiteSpace(c.Tenant) || string.Equals(c.Tenant, SystemTenant, StringComparison.OrdinalIgnoreCase));

    /// <summary>The overlays of the services' clients that live in other tenants, keyed by tenant (apps keep their client in their own tenant).</summary>
    public static Dictionary<string, string> RenderTenantOverlays(DevStackConfig shifted, SlotInfo slot, string slotDirectory,
        IReadOnlyCollection<string>? services = null)
    {
        var tenants = Selected(shifted, services).SelectMany(s => s.Value.IdentityClients).Select(c => c.Tenant)
            .Where(t => !string.IsNullOrWhiteSpace(t) && !string.Equals(t, SystemTenant, StringComparison.OrdinalIgnoreCase))
            .Select(t => t!).Distinct(StringComparer.OrdinalIgnoreCase).ToList();
        return tenants.ToDictionary(t => t, t =>
            $"# Identity overlay of octo-devstack stack slot '{slot.Name}' for the clients of tenant '{t}' - generated, do not edit.\n" +
            $"# Apply through the octo-cli context {InstallationName(slot)}_{t}.\n\n" +
            $"overlayName: local-dev-{slot.Name}-{t}\n\nclients:\n" +
            ClientsYaml(shifted, slot, slotDirectory, services, c => string.Equals(c.Tenant, t, StringComparison.OrdinalIgnoreCase)), StringComparer.OrdinalIgnoreCase);
    }

    private static IEnumerable<KeyValuePair<string, ServiceConfig>> Selected(DevStackConfig shifted, IReadOnlyCollection<string>? services) =>
        services == null ? shifted.Services : shifted.Services.Where(s => services.Contains(s.Key, StringComparer.Ordinal));

    /// <summary>The overlay entries of the services' identity clients (list items of `clients:`), URIs rendered for the slot.</summary>
    private static string ClientsYaml(DevStackConfig shifted, SlotInfo slot, string slotDirectory, IReadOnlyCollection<string>? services,
        Func<ServiceIdentityClient, bool> include)
    {
        var text = new System.Text.StringBuilder();
        foreach (var (name, service) in Selected(shifted, services).OrderBy(s => s.Key, StringComparer.Ordinal))
        {
            foreach (var client in service.IdentityClients.Where(c => !string.IsNullOrWhiteSpace(c.ClientId) && include(c)))
            {
                text.Append($"\n  # {name}{(service.Description is { Length: > 0 } d ? $" - {d}" : "")}\n  - clientId: {client.ClientId}\n");
                foreach (var (key, values) in new[]
                         {
                             ("redirectUris", client.RedirectUris), ("postLogoutRedirectUris", client.PostLogoutRedirectUris),
                             ("allowedCorsOrigins", client.AllowedCorsOrigins)
                         })
                {
                    if (values.Count == 0)
                    {
                        continue;
                    }

                    text.Append($"    {key}:\n");
                    foreach (var value in values)
                    {
                        text.Append($"      - {SlotDeriver.Render(value, shifted, slot, slotDirectory, name)}\n");
                    }
                }
            }
        }

        return text.ToString();
    }

    /// <summary>The octo-tools installation entry of the slot (the schema of docs/installations-config.md).</summary>
    public static JsonObject RenderInstallation(DevStackConfig shifted, SlotInfo slot)
    {
        var services = new JsonObject();
        foreach (var (key, service) in new[]
                 {
                     ("assets", "assetRepoServices"), ("identity", "identityServices"), ("bots", "botServices"),
                     ("communication", "communicationControllerServices"), ("reporting", "reportingServices"), ("ai", "aiServices")
                 })
        {
            try
            {
                services[key] = $"https://localhost:{SlotDeriver.Port(shifted, service, "https")}/";
            }
            catch (SlotDeriver.NotApplicableException)
            {
                // Not configured here: the installation has no such service.
            }
        }

        return new JsonObject { ["name"] = InstallationName(slot), ["services"] = services };
    }

    /// <summary>Writes both files; returns their paths. <paramref name="services"/>: as in <see cref="RenderOverlay"/>.</summary>
    public static SlotArtifactPaths Write(DevStackConfig shifted, SlotInfo slot, string slotDirectory, IReadOnlyCollection<string>? services = null)
    {
        var paths = PathsOf(slotDirectory);
        Directory.CreateDirectory(slotDirectory);
        string overlay;
        try
        {
            overlay = RenderOverlay(shifted, slot, slotDirectory, services);
        }
        catch (SlotDeriver.NotApplicableException e)
        {
            // The template names a platform service this configuration does not have; the clients of the configured
            // services (apps) still get their overlay.
            overlay = $"# The built-in overlay of slot '{slot.Name}' could not be rendered: {e.Message}.\n";
            try
            {
                if (SystemClientsYaml(shifted, slot, slotDirectory, services) is { Length: > 0 } clients)
                {
                    overlay += $"\noverlayName: local-dev-{slot.Name}\n\nclients:\n{clients}";
                }
            }
            catch (SlotDeriver.NotApplicableException)
            {
                // A client naming a service that is not configured either.
            }
        }

        WriteAtomically(paths.IdentityOverlay, overlay);
        WriteAtomically(paths.Installation, RenderInstallation(shifted, slot).ToJsonString(new JsonSerializerOptions { WriteIndented = true }) + "\n");
        var tenantOverlays = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        try
        {
            foreach (var (tenant, text) in RenderTenantOverlays(shifted, slot, slotDirectory, services))
            {
                var file = Path.Combine(slotDirectory, $"identity-overlay.{PathScope.Slug(tenant)}.yaml");
                WriteAtomically(file, text);
                tenantOverlays[tenant] = file;
            }
        }
        catch (SlotDeriver.NotApplicableException)
        {
            // A client naming a service that is not configured: no overlay for it.
        }

        return tenantOverlays.Count == 0 ? paths : paths with { TenantOverlays = tenantOverlays };
    }

    /// <summary>
    ///     The pwsh call that applies the overlay through the slot's octo-cli context (without touching the active one). The
    ///     pwsh runner loads octo-tools' profile.ps1, which imports Invoke-IdentityOverlay.
    /// </summary>
    public static string ApplyCommand(SlotInfo slot, string overlayFile, string tenant = SystemTenant)
    {
        var function = $"octo-cli-slot-{slot.Name}";
        return $"function global:{function} {{ & octo-cli --context {InstallationName(slot)}_{tenant} @args }}; " +
               $"Invoke-IdentityOverlay -OverlayFile {PwshRunner.Quote(overlayFile)} -OctoCli {function}";
    }

    public async Task<SlotAfterStart> AfterStartAsync(SlotRun run, DevStackConfig shifted, IReadOnlyList<ServicePlan> started, bool waited,
        CancellationToken cancellationToken)
    {
        var notes = new List<string>();
        var warnings = new List<string>();
        var slot = run.Slot;
        // The same clients as the overlay step writes: those of the services the slot runs (the started ones are live by now).
        var paths = Write(shifted, slot, run.SlotDirectory, run.RunningServices());
        notes.Add($"Slot '{slot.Name}': ports +{slot.PortOffset}, prefix {slot.Prefix}, logs in {Path.GetDirectoryName(started[0].LogFile)}. " +
                  "Use a separate browser profile for this slot's identity (cookies are not port-scoped).");
        notes.Add($"Tenant databases: a tenant created without a database name gets {slot.Prefix}_<tenant> (OCTO_SYSTEM__TENANTDATABASEPREFIX, " +
                  "AB#8797; services need engine-mongodb with AB#8797, older ones ignore it and use the name they are given). An explicit name without " +
                  "the prefix is refused, and the platform refuses an existing database on create and a database owned by another system database on " +
                  "attach (AB#4945); stack_verify lists tenant databases that two slots register.");

        // Clients of the started services that live in another tenant (an app's own client): their redirect URIs on this
        // slot's ports are a separate overlay, applied through that tenant's octo-cli context.
        foreach (var (tenant, file) in paths.TenantOverlays ?? new Dictionary<string, string>())
        {
            var names = started.Where(p => shifted.Services.TryGetValue(p.Name, out var s) &&
                                           s.IdentityClients.Any(c => string.Equals(c.Tenant, tenant, StringComparison.OrdinalIgnoreCase))).Select(p => p.Name).ToList();
            if (names.Count > 0)
            {
                notes.Add($"{string.Join(", ", names)}: the OIDC client of tenant '{tenant}' needs this slot's redirect URIs - overlay {file}. The overlay step " +
                          $"of stack_setup applies it once the context {InstallationName(slot)}_{tenant} exists (stack_setup with tenants=[\"{tenant}\"] " +
                          $"registers and logs it in), or: {ApplyCommand(slot, file, tenant)}");
            }
        }

        var identity = started.FirstOrDefault(p => p.Name == IdentityService);
        if (identity == null)
        {
            return new SlotAfterStart(notes, warnings);
        }

        var config = shifted;
        if (config.SlotOptions.SmokeCheck && waited)
        {
            var expected = identity.Env.GetValueOrDefault("OCTO_IDENTITY__AUTHORITYURL") ?? $"https://localhost:{SlotDeriver.Port(config, "identityServices", "https")}";
            var url = $"https://localhost:{SlotDeriver.Port(config, "identityServices", "https")}/.well-known/openid-configuration";
            if (await CheckIssuerAsync(url, expected, cancellationToken) is { } problem)
            {
                warnings.Add($"Smoke check of slot '{slot.Name}': {problem}");
            }
            else
            {
                notes.Add($"Smoke check of slot '{slot.Name}': the identity issuer is {expected.TrimEnd('/')}/.");
            }
        }

        return new SlotAfterStart(notes, warnings);
    }

    /// <summary>GETs a discovery document and compares its issuer with <paramref name="expected"/> (trailing slash ignored). Null: they match.</summary>
    public static async Task<string?> CheckIssuerAsync(string discoveryUrl, string expected, CancellationToken cancellationToken)
    {
        try
        {
            using var response = await Http.GetAsync(discoveryUrl, cancellationToken);
            if (!response.IsSuccessStatusCode)
            {
                return $"GET {discoveryUrl} -> {(int)response.StatusCode}; the issuer was not checked.";
            }

            var document = JsonNode.Parse(await response.Content.ReadAsStringAsync(cancellationToken));
            var issuer = document?["issuer"]?.GetValue<string>();
            if (issuer == null)
            {
                return $"{discoveryUrl} has no issuer.";
            }

            return string.Equals(issuer.TrimEnd('/'), expected.TrimEnd('/'), StringComparison.OrdinalIgnoreCase)
                ? null
                : $"the identity server issues tokens as '{issuer}', but the slot's services expect '{expected}'. Tokens will be rejected; " +
                  "check OCTO_IDENTITY__AUTHORITYURL and the authority settings of the slot.";
        }
        catch (Exception e) when (e is HttpRequestException or TaskCanceledException or JsonException or InvalidOperationException)
        {
            return $"GET {discoveryUrl} failed ({e.GetType().Name}: {e.Message}); the issuer was not checked.";
        }
    }

    private static void WriteAtomically(string file, string text)
    {
        var temp = file + ".tmp";
        File.WriteAllText(temp, text);
        Common.SharedFile.Replace(temp, file);
    }
}
