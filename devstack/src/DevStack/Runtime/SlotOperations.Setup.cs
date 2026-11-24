using System.Text.Json;
using System.Text.Json.Serialization;
using Meshmakers.Octo.DevStack.Common;
using Meshmakers.Octo.DevStack.Configuration;

namespace Meshmakers.Octo.DevStack.Runtime;

/// <summary>The steps of a slot's setup, in the order they run.</summary>
public static class SlotSetupSteps
{
    /// <summary>The first admin of a fresh system database (identity setup API; the password stays in an owner-only file).</summary>
    public const string Admin = "admin";

    /// <summary>The octo-tools installation entry local-&lt;slot&gt; and the octo-cli contexts local-&lt;slot&gt;_&lt;tenant&gt;.</summary>
    public const string OctoCli = "octoCli";

    /// <summary>The client-credentials client devstack-&lt;slot&gt; (created once with the admin) and the login of the contexts with it.</summary>
    public const string Login = "login";

    /// <summary>The identity overlay: the redirect URIs of the clients on the slot's shifted ports.</summary>
    public const string Overlay = "overlay";

    public static readonly IReadOnlyList<string> All = [Admin, OctoCli, Login, Overlay];

    /// <summary>The steps asked for, in the order they run; null or empty means all. An unknown name is refused.</summary>
    public static IReadOnlyList<string> Select(IReadOnlyList<string>? steps)
    {
        if (steps == null || steps.Count == 0)
        {
            return All;
        }

        var unknown = steps.Where(s => !All.Contains(s.Trim(), StringComparer.OrdinalIgnoreCase)).ToList();
        if (unknown.Count > 0)
        {
            throw new ArgumentException($"Unknown setup step(s) {string.Join(", ", unknown.Select(s => $"'{s}'"))}; the steps are {string.Join(", ", All)}.");
        }

        return All.Where(a => steps.Any(s => string.Equals(s.Trim(), a, StringComparison.OrdinalIgnoreCase))).ToList();
    }
}

/// <summary>One step of a slot's setup: done (it changed something), unchanged (nothing to do), failed, skipped (a step it needs failed).</summary>
public sealed record SlotSetupStep(string Step, string Status, string Summary);

/// <summary>
///     The outcome of a slot's setup (after a start or from stack_setup). Secrets are never part of it: the admin password
///     and the client secret stay in their owner-only files, which it names.
/// </summary>
public sealed record SlotSetupResult(
    string Slot,
    int Index,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    string? Lane,
    string Trigger,
    DateTimeOffset At,
    bool Success,
    IReadOnlyList<SlotSetupStep> Steps,
    IReadOnlyList<string> Warnings,
    [property: JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    IReadOnlyList<string>? Shell = null)
{
    /// <summary>The start result's note: every step in a few words.</summary>
    public string Summary() =>
        $"Setup of {(Lane != null ? $"lane stack '{Lane}'" : $"slot '{Slot}'")} ({Trigger}): " +
        string.Join("; ", Steps.Select(s => $"{s.Step} {s.Status}")) + (Success ? "." : " - see setup.warnings.");
}

/// <summary>Runs the setup of a non-default slot after a start that brought its identity service up healthy (SlotRun's start path).</summary>
public interface ISlotSetup
{
    /// <summary>The setup of the slot <paramref name="run"/> (of lane <paramref name="lane"/>, if any); never throws for a failed step.</summary>
    Task<SlotSetupResult> AfterHealthyStartAsync(SlotRun run, string? lane, CancellationToken cancellationToken);
}

public sealed partial class SlotOperations : ISlotSetup
{
    /// <summary>The file in the slot's state folder that keeps the last setup (stack_list, stack_status).</summary>
    public const string SetupFileName = "stack-setup.json";

    private static readonly JsonSerializerOptions SetupJson = new(JsonSerializerDefaults.Web) { WriteIndented = true };

    /// <summary>One setup per slot at a time: every session of a lane holds its lease, and two first logins would both create the client.</summary>
    private readonly System.Collections.Concurrent.ConcurrentDictionary<string, SemaphoreSlim> _setupLocks = new(StringComparer.Ordinal);

    /// <summary>
    ///     stack_setup: runs the given steps (all by default) of a lane stack or a named slot again. Every step is
    ///     idempotent; a failed step is reported with the call that repeats it, and the next steps run when they do not
    ///     need it.
    /// </summary>
    public async Task<SlotSetupResult> SetupAsync(string owner, string? lane, string? slot, IReadOnlyList<string>? steps, IReadOnlyList<string> tenants,
        bool renew, CancellationToken cancellationToken)
    {
        var selected = SlotSetupSteps.Select(steps);
        LoginTenants(SystemTenant(store.Load()), tenants);
        var target = Resolve(lane, slot);
        Claim(target, owner);
        return await RunSetupAsync(target, selected, tenants, renew, "stack_setup", cancellationToken);
    }

    /// <summary>
    ///     The automatic setup after a start of the slot's identity service (the start holds the slot's lease already): all
    ///     steps for the system tenant. On a fresh system database it creates the admin, the octo-cli contexts and the
    ///     client and applies the overlay; later starts find everything there and only log the contexts in again.
    /// </summary>
    public async Task<SlotSetupResult> AfterHealthyStartAsync(SlotRun run, string? lane, CancellationToken cancellationToken)
    {
        try
        {
            var target = Resolve(lane, lane == null ? run.Slot.Name : null);
            return await RunSetupAsync(target, SlotSetupSteps.All, [], false, "after the start", cancellationToken);
        }
        catch (Exception e) when (e is ArgumentException or InvalidOperationException or IOException or UnauthorizedAccessException)
        {
            var result = new SlotSetupResult(run.Slot.Name, run.Slot.Index, lane, "after the start", DateTimeOffset.Now, false, [],
                [$"The setup of slot '{run.Slot.Name}' did not run: {e.Message.TrimEnd('.')}. Repair: {RepairCall(lane, run.Slot.Name, null)}."]);
            SaveSetup(run.Slot, result);
            return result;
        }
    }

    /// <summary>The last setup of the slot, or null when none ran for its current index (a slot of the same name before had another one).</summary>
    public static SlotSetupResult? LastSetup(string stateDirectory, SlotInfo slot)
    {
        var file = Path.Combine(SlotDeriver.SlotDirectory(stateDirectory, slot), SetupFileName);
        try
        {
            var result = File.Exists(file) ? JsonSerializer.Deserialize<SlotSetupResult>(Common.SharedFile.ReadAllText(file), SetupJson) : null;
            return result?.Index == slot.Index ? result : null;
        }
        catch (Exception e) when (e is IOException or JsonException or UnauthorizedAccessException)
        {
            return null;
        }
    }

    private void SaveSetup(SlotInfo slot, SlotSetupResult result)
    {
        var folder = SlotDeriver.SlotDirectory(supervisor.StateDirectory, slot);
        try
        {
            Directory.CreateDirectory(folder);
            var file = Path.Combine(folder, SetupFileName);
            var temp = file + ".tmp";
            File.WriteAllText(temp, JsonSerializer.Serialize(result with { Shell = null }, SetupJson));
            Common.SharedFile.Replace(temp, file);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            // The answer still carries the result; only stack_list will not show it.
        }
    }

    /// <summary>The call that repeats a step (or all of them) of this lane or slot.</summary>
    internal static string RepairCall(string? lane, string slot, string? step) =>
        $"stack_setup(owner, {(lane != null ? $"lane=\"{lane}\"" : $"slot=\"{slot}\"")}{(step != null ? $", steps=[\"{step}\"]" : "")})";

    private async Task<SlotSetupResult> RunSetupAsync(SlotTarget target, IReadOnlyList<string> steps, IReadOnlyList<string> tenants, bool renew, string trigger,
        CancellationToken cancellationToken)
    {
        var gate = _setupLocks.GetOrAdd(target.Slot.Name, _ => new SemaphoreSlim(1, 1));
        await gate.WaitAsync(cancellationToken);
        try
        {
            var result = await RunStepsAsync(target, steps, tenants, renew, trigger, cancellationToken);
            // Saved under the gate: a later setup of the slot cannot finish first and then be overwritten by this older result.
            SaveSetup(target.Slot, result);
            return result;
        }
        finally
        {
            gate.Release();
        }
    }

    private async Task<SlotSetupResult> RunStepsAsync(SlotTarget target, IReadOnlyList<string> steps, IReadOnlyList<string> tenants, bool renew, string trigger,
        CancellationToken cancellationToken)
    {
        var done = new List<SlotSetupStep>();
        var warnings = new List<string>();
        IReadOnlyList<string>? shell = null;
        var systemTenant = SystemTenant(store.Load());
        // The same names for the registration and the login: octo-cli refuses a login into a context matched only by case.
        var allTenants = LoginTenants(systemTenant, tenants);
        bool Failed(string step) => done.Any(s => s.Step == step && s.Status is "failed" or "skipped");

        void Fail(string step, string why)
        {
            done.Add(new SlotSetupStep(step, "failed", why));
            warnings.Add($"Setup step '{step}' of {(target.Environment != null ? $"lane stack '{target.Environment}'" : $"slot '{target.Slot.Name}'")} failed: " +
                         $"{why.TrimEnd('.')}. Repair: {RepairCall(target.Environment, target.Slot.Name, step)}.");
        }

        async Task Step(string step, Func<Task<SlotSetupStep>> run)
        {
            try
            {
                var outcome = await run();
                if (outcome.Status == "failed")
                {
                    Fail(step, outcome.Summary);
                }
                else
                {
                    done.Add(outcome);
                }
            }
            catch (Exception e) when (e is InvalidOperationException or IOException or UnauthorizedAccessException or JsonException or HttpRequestException)
            {
                Fail(step, e.Message);
            }
        }

        if (steps.Contains(SlotSetupSteps.Admin))
        {
            await Step(SlotSetupSteps.Admin, async () =>
            {
                var admin = await BootstrapAdminCoreAsync(target, null, cancellationToken);
                return new SlotSetupStep(SlotSetupSteps.Admin, admin.Status == "created" ? "done" : "unchanged", admin.Note);
            });
        }

        var registered = false;
        if (steps.Contains(SlotSetupSteps.OctoCli))
        {
            await Step(SlotSetupSteps.OctoCli, async () =>
            {
                var registration = await RegisterOctoCliCoreAsync(target, allTenants, false, cancellationToken);
                registered = registration.Success;
                return registration.Success
                    ? new SlotSetupStep(SlotSetupSteps.OctoCli, "done",
                        $"{registration.Notes[0]} Contexts {string.Join(", ", registration.Contexts)} (the active context was not changed).")
                    : new SlotSetupStep(SlotSetupSteps.OctoCli, "failed",
                        $"Register-OctoCliContext failed: {PwshErrors.Summary(registration.OutputTail)}");
            });
        }

        if (steps.Contains(SlotSetupSteps.Login))
        {
            if (Failed(SlotSetupSteps.OctoCli))
            {
                done.Add(new SlotSetupStep(SlotSetupSteps.Login, "skipped", "The octo-cli contexts are not registered (step octoCli failed)."));
            }
            else
            {
                await Step(SlotSetupSteps.Login, async () =>
                {
                    var login = await LoginCoreAsync(target, tenants, renew, register: !registered, cancellationToken);
                    shell = login.Shell;
                    var contexts = string.Join(", ", login.Contexts.Select(c => c.Name));
                    if (login.Success)
                    {
                        return new SlotSetupStep(SlotSetupSteps.Login, "done",
                            (login.Created ? $"Client {login.ClientId} created (secret in {login.SecretFile}); " : $"Client {login.ClientId}: ") +
                            $"logged in {contexts} with it. The token lasts about an hour: {RepairCall(target.Environment, target.Slot.Name, SlotSetupSteps.Login)} " +
                            "logs in again, or export the lines of 'shell' so octo-cli re-acquires it.");
                    }

                    var why = login.Contexts.Where(c => !c.LoggedIn && c.Note != null).Select(c => $"{c.Name}: {c.Note}")
                        .Concat(login.Notes.Skip(1)).ToList();
                    return new SlotSetupStep(SlotSetupSteps.Login, "failed", why.Count > 0 ? string.Join(" ", why) : "The login gave no result.");
                });
            }
        }

        if (steps.Contains(SlotSetupSteps.Overlay))
        {
            if (Failed(SlotSetupSteps.Login))
            {
                done.Add(new SlotSetupStep(SlotSetupSteps.Overlay, "skipped", "The octo-cli context is not logged in (step login failed)."));
            }
            else
            {
                await Step(SlotSetupSteps.Overlay, async () =>
                {
                    // AB#9676: the tenants' own overlays only for the tenants this setup logged in: a context of another tenant
                    // may be left from an earlier stack of the same slot name, for a tenant this stack does not have (a fresh lane
                    // has only the system tenant).
                    var overlay = await ApplyOverlayCoreAsync(target, cancellationToken, steps.Contains(SlotSetupSteps.Login) ? allTenants : null);
                    return overlay.Success
                        ? new SlotSetupStep(SlotSetupSteps.Overlay, "done", string.Join(" ", overlay.Notes))
                        : new SlotSetupStep(SlotSetupSteps.Overlay, "failed", "Identity overlay failed: " + string.Join(" ", overlay.Notes));
                });
            }
        }

        return new SlotSetupResult(target.Slot.Name, target.Slot.Index, target.Environment, trigger, DateTimeOffset.Now,
            done.All(s => s.Status is "done" or "unchanged"), done, warnings, shell);
    }
}
