using System.Security.Cryptography;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.Json.Serialization;
using Meshmakers.Octo.DevStack.Builds;
using Meshmakers.Octo.DevStack.Common;
using Meshmakers.Octo.DevStack.Configuration;

namespace Meshmakers.Octo.DevStack.Runtime;

/// <summary>The login step of stack_setup: one octo-cli context of the slot.</summary>
public sealed record SlotLoginContext(
    string Name,
    bool LoggedIn,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    string? Note);

/// <summary>The login step of stack_setup: the slot's client-credentials client and the contexts logged in with it. The secret is only in the owner-only file.</summary>
public sealed record SlotLoginResult(
    string Slot,
    string ClientId,
    string SecretFile,
    bool Created,
    bool Success,
    IReadOnlyList<SlotLoginContext> Contexts,
    IReadOnlyList<string> Shell,
    IReadOnlyList<string> Notes,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    string? OutputTail);

public sealed partial class SlotOperations
{
    public const string ClientSecretFileName = "octo-cli-client.secret";

    /// <summary>The client-credentials client of a slot (one per slot, in its system tenant).</summary>
    public static string LoginClientId(SlotInfo slot) => $"devstack-{slot.Name}";

    /// <summary>
    ///     The tenants of a login or registration: the system tenant first (the client lives there, and its context carries
    ///     the admin step), then the others lowercased without duplicates. A name that is no tenant id is refused.
    /// </summary>
    internal static List<string> LoginTenants(string systemTenant, IReadOnlyList<string> tenants)
    {
        var all = tenants.Where(t => !string.IsNullOrWhiteSpace(t)).Select(t => t.Trim().ToLowerInvariant()).Distinct().ToList();
        all.RemoveAll(t => string.Equals(t, systemTenant, StringComparison.OrdinalIgnoreCase));
        all.Insert(0, systemTenant);
        foreach (var tenant in all.Where(t => !System.Text.RegularExpressions.Regex.IsMatch(t, "^[a-z0-9][a-z0-9_-]*$")))
        {
            throw new ArgumentException($"'{tenant}' is no tenant id.");
        }

        return all;
    }

    /// <summary>
    ///     The login step of stack_setup (AB#8834): a login for the slot's octo-cli contexts that needs no browser. The first
    ///     call creates the client-credentials client devstack-&lt;slot&gt; (role TenantManagement, mirrored into child tenants)
    ///     in the slot's system tenant - with the admin of the admin step, whose device login is approved over the identity API
    ///     - and keeps its secret in an owner-only file; every call logs the contexts in with that client (--context, the
    ///     active context never changes). The secret and the admin password never leave their files.
    /// </summary>
    internal async Task<SlotLoginResult> LoginAsync(string owner, string? lane, string? slot, IReadOnlyList<string> tenants, bool renew,
        CancellationToken cancellationToken)
    {
        var target = Resolve(lane, slot);
        Claim(target, owner);
        return await LoginCoreAsync(target, tenants, renew, register: true, cancellationToken);
    }

    /// <param name="register">
    ///     Register the contexts first (Register-OctoCliContext -NoLogin: they exist, and a login left in them is gone); false
    ///     when the caller registered the same tenants just before.
    /// </param>
    private async Task<SlotLoginResult> LoginCoreAsync(SlotTarget target, IReadOnlyList<string> tenants, bool renew, bool register,
        CancellationToken cancellationToken)
    {
        var config = store.Load();
        var systemTenant = SystemTenant(config);
        var all = LoginTenants(systemTenant, tenants);
        var clientId = LoginClientId(target.Slot);
        var secretFile = Path.Combine(target.FilesFolder, ClientSecretFileName);
        var adminFile = Path.Combine(target.FilesFolder, CredentialsFileName);
        var needsClient = renew || !File.Exists(secretFile);
        if (needsClient && !File.Exists(adminFile))
        {
            throw new InvalidOperationException(
                $"Creating the client {clientId} needs the slot's admin, but there is no {adminFile} (the admin step writes it for a fresh system database). " +
                "For a slot whose admin was created by hand: create the client once yourself (octo-cli -c AddClientCredentialsClient -id " +
                $"{clientId} --secret-stdin -apic, then AddClientToRole -id {clientId} -r TenantManagement), put its secret into {secretFile} (mode 600) and call " +
                $"{RepairCall(target.Environment, target.Slot.Name, SlotSetupSteps.Login)} again.");
        }

        var installation = SlotArtifacts.InstallationName(target.Slot);
        var notes = new List<string>();
        if (register)
        {
            var registration = await RegisterOctoCliCoreAsync(target, all, false, cancellationToken);
            notes.Add(registration.Notes[0]);
            if (!registration.Success)
            {
                notes.Add("Registering the octo-cli contexts failed; nothing else was done.");
                return new SlotLoginResult(target.Slot.Name, clientId, secretFile, false, false, [], ShellLines(clientId, secretFile), notes, registration.OutputTail);
            }
        }
        else
        {
            notes.Add($"Contexts of installation '{installation}' registered by the octoCli step.");
        }

        var contexts = all.Select(t => $"{installation}_{t}").ToList();
        var shell = ShellLines(clientId, secretFile);

        string? previousSecret = null;
        if (needsClient)
        {
            if (File.Exists(secretFile))
            {
                previousSecret = File.ReadAllText(secretFile);
                File.Delete(secretFile);
            }

            // The secret exists on disk before the client does: a client whose secret nobody kept would have to be recreated.
            Directory.CreateDirectory(target.FilesFolder);
            WriteOwnerOnly(secretFile, Convert.ToBase64String(RandomNumberGenerator.GetBytes(32)) + "\n");
        }

        var identity = $"https://localhost:{SlotDeriver.Port(target.Shifted, "identityServices", "https")}";
        var script = LoginScript(clientId, target.Slot.Name, secretFile, adminFile, identity, systemTenant, installation, contexts, needsClient, renew);
        // OCTO_TOOLS_CONFIG: the script registers the system context again after the admin's device login (as RegisterOctoCliAsync does).
        var result = await pwsh.RunAsync(ServicePlanner.OctoToolsPath(config), BuildPlanner.RootPrelude(ServicePlanner.RootPath(config)) + script,
            new PwshRunOptions { Timeout = TimeSpan.FromMinutes(5), Environment = new Dictionary<string, string?> { ["OCTO_TOOLS_CONFIG"] = OctoToolsConfigFile } },
            cancellationToken);
        JsonObject? marker = null;
        try
        {
            marker = PwshRunner.ExtractMarker(result.Output) as JsonObject;
        }
        catch (JsonException)
        {
            // No readable result: reported below with the output tail.
        }

        var created = marker?["created"]?.GetValue<bool>() == true;
        var error = marker?["error"]?.GetValue<string>();
        var states = (marker?["contexts"] as JsonArray ?? []).OfType<JsonObject>()
            .Select(c => new SlotLoginContext(c["name"]?.GetValue<string>() ?? "", c["loggedIn"]?.GetValue<bool>() == true, c["note"]?.GetValue<string>()))
            .ToList();
        if (needsClient && !created)
        {
            // No client was created with the new secret: the file would only mislead the next call.
            File.Delete(secretFile);
            if (previousSecret != null)
            {
                WriteOwnerOnly(secretFile, previousSecret);
            }
        }

        var success = marker != null && error == null && states.Count == contexts.Count && states.All(s => s.LoggedIn);
        if (created)
        {
            notes.Add($"Client {clientId} created in the system tenant '{systemTenant}' of slot '{target.Slot.Name}' (role TenantManagement, mirrored into child " +
                      $"tenants); its secret is in {secretFile} (owner-only).");
        }

        if (error != null)
        {
            notes.Add($"Failed at step '{marker?["step"]?.GetValue<string>()}': {Scrub(error, secretFile, adminFile)}");
            if (created)
            {
                // The client exists with the kept secret, but its role or its mirrors into the child tenants are missing: a
                // repeat without renew skips the creation (the secret file is there), so only renew=true completes it.
                notes.Add($"Client {clientId} was created, but its provisioning did not finish: call " +
                          $"{RepairCall(target.Environment, target.Slot.Name, SlotSetupSteps.Login)[..^1]}, renew=true) - it creates the client anew, with its role and mirrors.");
            }
        }
        else if (marker == null)
        {
            notes.Add($"The login script gave no result (exit {result.ExitCode}{(result.TimedOut ? ", timed out" : "")}): " +
                      $"{Scrub(PwshErrors.Summary(result.Output), secretFile, adminFile)}");
        }

        if (marker?["adminLoginKept"]?.GetValue<string>() is { } kept)
        {
            notes.Add($"The admin's device login could not be removed from {contexts[0]} ({Scrub(kept, secretFile, adminFile)}); octo-cli refuses to replace an " +
                      $"interactive login with the client's. Run Register-OctoCliContext -Installation {installation} -TenantId {systemTenant} -NoSwitch -NoLogin, " +
                      $"then {RepairCall(target.Environment, target.Slot.Name, SlotSetupSteps.Login)}.");
        }

        if (states.Any(s => !s.LoggedIn) && !needsClient)
        {
            notes.Add($"A context that cannot log in with an existing secret file usually means the slot's system database is new (client {clientId} is gone) " +
                      $"or the client was created without this secret: call {RepairCall(target.Environment, target.Slot.Name, SlotSetupSteps.Login)[..^1]}, renew=true).");
        }

        if (success)
        {
            notes.Add($"The token lasts about an hour and has no refresh token: call {RepairCall(target.Environment, target.Slot.Name, SlotSetupSteps.Login)} again " +
                      "(also after a slot restart), or export the variables " +
                      "of 'shell' so octo-cli re-acquires it by itself (they read the secret from the file when they run and do not contain it). Always pass --context <name>; the active context was not changed.");
            notes.Add("In a child tenant the client has roles only where it created the tenant itself (octo-cli -c Create -tid <t> --scratch " +
                      $"--context {contexts[0]}); other tenants need a role or group for the client there.");
        }

        return new SlotLoginResult(target.Slot.Name, clientId, secretFile, created, success, states, shell, notes,
            marker != null ? null : Scrub(PwshRunner.Tail(result.Output, 20), secretFile, adminFile));
    }

    /// <summary>What a shell needs so octo-cli re-acquires the token itself; the secret is read from the file, never printed.</summary>
    internal static IReadOnlyList<string> ShellLines(string clientId, string secretFile) =>
    [
        $"export OCTO_CLI_CLIENT_ID={clientId}",
        $"IFS= read -r OCTO_CLI_CLIENT_SECRET < '{secretFile.Replace("'", "'\\''")}' || [ -n \"$OCTO_CLI_CLIENT_SECRET\" ]",
        "export OCTO_CLI_CLIENT_SECRET"
    ];

    /// <summary>Removes the client secret and the admin password from text that goes into an answer (belt and braces: the script prints neither).</summary>
    private static string Scrub(string text, string secretFile, string adminFile)
    {
        try
        {
            if (File.Exists(secretFile) && File.ReadAllText(secretFile).Trim() is { Length: > 0 } secret)
            {
                text = text.Replace(secret, "***");
            }

            if (File.Exists(adminFile) && JsonNode.Parse(File.ReadAllText(adminFile))?["password"]?.GetValue<string>() is { Length: > 0 } password)
            {
                text = text.Replace(password, "***");
            }
        }
        catch (Exception e) when (e is IOException or JsonException or UnauthorizedAccessException or InvalidOperationException)
        {
            // Unreadable files hold nothing that could have been printed from them.
        }

        return text;
    }

    /// <summary>
    ///     The PowerShell script of the login step. Secrets are read from their files inside the script and handed to octo-cli
    ///     through environment variables of that one call; nothing secret is on a command line or in the output. The last
    ///     line is the marker with { created, step, error, adminLoginKept, contexts[{ name, loggedIn, note }] }.
    ///     <para>
    ///         Creating the client needs the admin's token: an octo-cli device login into the system context, approved with
    ///         the admin's session. That login is only the means: once the client exists (or its creation failed) the script
    ///         registers the system context again without a login (Register-OctoCliContext -NoLogin, i.e. octo-cli AddContext,
    ///         which writes the context anew). octo-cli's LogInClientCredentials refuses to replace an interactive login
    ///         (AB#9063: the context holds a refresh token), so without that the first call failed for the system context,
    ///         and only a second call - whose registration had dropped the device login - succeeded. The admin's refresh
    ///         token does not stay in contexts.json either.
    ///     </para>
    /// </summary>
    /// <param name="octoCli">The octo-cli command: executable and leading arguments (tests run a fake through pwsh); default octo-cli.</param>
    internal static string LoginScript(string clientId, string slot, string secretFile, string adminFile, string identity, string systemTenant,
        string installation, IReadOnlyList<string> contexts, bool createClient, bool renew, IReadOnlyList<string>? octoCli = null)
    {
        var q = (Func<string, string>)PwshRunner.Quote;
        var cli = octoCli is { Count: > 0 } ? octoCli : ["octo-cli"];
        return $$"""
                 $r = [ordered]@{ created = $false; step = 'start'; error = $null; adminLoginKept = $null; contexts = @() }
                 $cliExe = {{q(cli[0])}}
                 $cliPre = @({{string.Join(", ", cli.Skip(1).Select(q))}})
                 function Invoke-SlotCli {
                     param([string[]] $CliArgs)
                     $out = & $cliExe @cliPre @CliArgs 2>&1 | Out-String
                     if ($LASTEXITCODE -ne 0) {
                         $last = ($out -split "`n" | Where-Object { $_.Trim() } | Select-Object -Last 3 | ForEach-Object { $_.Trim() }) -join ' | '
                         throw "octo-cli -c $($CliArgs[1]) failed (exit $LASTEXITCODE): $last"
                     }
                 }
                 try {
                     $clientId = {{q(clientId)}}
                     $systemContext = {{q(contexts[0])}}
                     $secret = (Get-Content -Raw -LiteralPath {{q(secretFile)}}).Trim()
                     if ({{(createClient ? "$true" : "$false")}}) {
                         try {
                             $r.step = 'adminLogin'
                             $cred = Get-Content -Raw -LiteralPath {{q(adminFile)}} | ConvertFrom-Json
                             Remove-Item Env:OCTO_CLI_CLIENT_ID, Env:OCTO_CLI_CLIENT_SECRET -ErrorAction SilentlyContinue
                             $log = [System.IO.Path]::GetTempFileName()
                             # Start-Process joins the arguments with spaces: one with a space is quoted. -NoNewWindow: on Windows the
                             # child shares the script's (hidden) console instead of opening a visible window.
                             $loginArgs = @($cliPre + @('-c', 'LogIn', '--context', $systemContext) | ForEach-Object { if ("$_" -match '\s') { '"' + $_ + '"' } else { $_ } })
                             $p = Start-Process -FilePath $cliExe -ArgumentList $loginArgs -RedirectStandardOutput $log -NoNewWindow -PassThru
                             try {
                                 $code = $null
                                 $deadline = (Get-Date).AddSeconds(60)
                                 while (-not $code -and (Get-Date) -lt $deadline) {
                                     Start-Sleep -Milliseconds 500
                                     $text = Get-Content -Raw -LiteralPath $log -ErrorAction SilentlyContinue
                                     if ($text -match 'Enter the code:\s*([0-9A-Za-z-]+)') { $code = $Matches[1] }
                                     elseif ($p.HasExited) { break }
                                 }
                                 if (-not $code) { throw "octo-cli -c LogIn printed no device code for $systemContext (is the identity service of the slot running?)" }
                                 $session = [Microsoft.PowerShell.Commands.WebRequestSession]::new()
                                 $body = @{ username = $cred.email; password = $cred.password; rememberLogin = $false } | ConvertTo-Json
                                 $login = Invoke-RestMethod -Method Post -Uri {{q($"{identity}/{systemTenant}/api/auth/login")}} -WebSession $session `
                                     -SkipCertificateCheck -ContentType 'application/json' -Body $body
                                 if (-not $login.success) {
                                     $why = if ($login.requiresTwoFactor) { 'the account asks for a second factor' } elseif ($login.isLockedOut) { 'the account is locked out' } else { 'wrong e-mail or password' }
                                     throw "The admin of the credentials file cannot sign in at the slot's identity service: $why."
                                 }
                                 $approval = Invoke-RestMethod -Method Post -Uri {{q($"{identity}/connect/deviceverification")}} -WebSession $session `
                                     -SkipCertificateCheck -ContentType 'application/x-www-form-urlencoded' -Body @{ user_code = $code }
                                 if (-not $approval.success) { throw "The device login was not approved: $($approval.errorMessage)" }
                                 if (-not $p.WaitForExit(90000)) { throw 'octo-cli -c LogIn did not finish after the approval.' }
                                 if ((Get-Content -Raw -LiteralPath $log) -notmatch 'Device log-in successful') { throw 'octo-cli -c LogIn did not report a successful device login.' }
                             }
                             finally {
                                 if (-not $p.HasExited) { $p.Kill() }
                                 Remove-Item -LiteralPath $log -ErrorAction SilentlyContinue
                             }
                             $r.step = 'createClient'
                             if ({{(renew ? "$true" : "$false")}}) { & $cliExe @cliPre -c DeleteClient -id $clientId -y --context $systemContext *> $null }
                             $env:OCTO_CLI_NEW_CLIENT_SECRET = $secret
                             try {
                                 Invoke-SlotCli @('-c', 'AddClientCredentialsClient', '-id', $clientId, '-n', {{q($"octo-devstack slot {slot} (non-interactive)")}}, '-apic', '--context', $systemContext)
                             }
                             finally { Remove-Item Env:OCTO_CLI_NEW_CLIENT_SECRET }
                             $r.created = $true
                             $r.step = 'assignRole'
                             Invoke-SlotCli @('-c', 'AddClientToRole', '-id', $clientId, '-r', 'TenantManagement', '--context', $systemContext)
                             $r.step = 'provisionMirrors'
                             Invoke-SlotCli @('-c', 'ProvisionClientInExistingTenants', '-id', $clientId, '--context', $systemContext)
                         }
                         finally {
                             # The device login was only the means to create the client: the system context is registered anew, without a login.
                             try {
                                 $again = Register-OctoCliContext -Installation {{q(installation)}} -TenantId {{q(systemTenant)}} -NoSwitch -NoLogin -Json | Out-String | ConvertFrom-Json
                                 if (-not $again.data.success) { $r.adminLoginKept = "Register-OctoCliContext failed (exit $($again.data.exitCode))" }
                             }
                             catch { $r.adminLoginKept = $_.Exception.Message }
                         }
                     }
                     $r.step = 'login'
                     $env:OCTO_CLI_CLIENT_ID = $clientId
                     $env:OCTO_CLI_CLIENT_SECRET = $secret
                     foreach ($context in @({{string.Join(", ", contexts.Select(q))}})) {
                         try {
                             Invoke-SlotCli @('-c', 'LogInClientCredentials', '--context', $context)
                             $r.contexts += @{ name = $context; loggedIn = $true }
                         }
                         catch { $r.contexts += @{ name = $context; loggedIn = $false; note = $_.Exception.Message } }
                     }
                     $r.step = 'done'
                 }
                 catch { $r.error = $_.Exception.Message }
                 finally { Remove-Item Env:OCTO_CLI_CLIENT_SECRET, Env:OCTO_CLI_NEW_CLIENT_SECRET -ErrorAction SilentlyContinue }
                 '{{PwshRunner.Marker}} ' + ($r | ConvertTo-Json -Compress -Depth 5)
                 """;
    }
}
