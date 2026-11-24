using System.ComponentModel;
using Meshmakers.Octo.DevStack.Runtime;
using ModelContextProtocol.Server;

namespace Meshmakers.Octo.DevStack.Tools;

/// <summary>Setup and verification of a lane stack (or of a named slot's stack), and the environment of its services.</summary>
[McpServerToolType]
public sealed class SlotOpsTools(SlotOperations operations)
{
    internal const string LaneDescription = "Lane (octo-tools: feature environment; lane_list) whose stack is meant. Pass lane or slot.";
    internal const string SlotDescription = "A named stack slot that is no lane (stack_list), when no lane is given.";

    [McpServerTool(Name = "stack_setup")]
    [Description("Sets a lane stack (or a named slot's stack) up for use, or repeats a step of it: the daemon runs the same setup by itself once the " +
                 "stack's identity service is healthy after stack_start, so call this only when a step failed (the start result's warnings name it), " +
                 "after slotOptions.autoSetup was off, or to log in again when the token (about an hour) expired. Steps, in this order, each idempotent: " +
                 "'admin' - the first admin of the stack's fresh system database (identity setup API; the password goes to an owner-only file " +
                 "<lane>/.octo/admin-credentials.json, never into an answer; nothing happens when the database has users or the file exists); 'octoCli' - " +
                 "the octo-tools installation entry local-<slot> (shifted URLs, merged into the octo-tools config with a backup) and the octo-cli contexts " +
                 "local-<slot>_<tenant>, the active context never changes; 'login' - a client-credentials client devstack-<slot> (role TenantManagement), " +
                 "created once with the admin, its secret in <lane>/.octo/octo-cli-client.secret, and the login of the contexts with it (no browser); " +
                 "'overlay' - the identity overlay (redirect URIs of the clients on the shifted ports). steps (default all) picks some, e.g. ['login']. " +
                 "The answer has every step's outcome (done, unchanged, failed with the reason, skipped when a step it needs failed), warnings with the " +
                 "call that repeats a failed step, and 'shell' - the lines that let octo-cli re-acquire the token by itself; stack_list and stack_status " +
                 "show the last setup. Needs the stack's identity service running and the stack's lease (a lane's stack holds its own). Not for the shared stack.")]
    public Task<SlotSetupResult> Setup(
        [Description(StackTools.OwnerDescription)] string owner,
        [Description(LaneDescription)] string? lane = null,
        [Description(SlotDescription)] string? slot = null,
        [Description("Steps to run, in their fixed order: admin, octoCli, login, overlay. Default: all.")] List<string>? steps = null,
        [Description("Further tenants to register and log in besides the system tenant, e.g. ['meshtest'] (in a child tenant the client has roles only " +
                     "where it created the tenant itself: octo-cli -c Create -tid <t> --scratch --context local-<slot>_octosystem).")] List<string>? tenants = null,
        [Description("Delete and recreate the client with a new secret (a new system database, a lost secret); needs the admin credentials file.")] bool renew = false,
        [Description(StackTools.SessionDescription)] string? session = null,
        CancellationToken cancellationToken = default) =>
        ToolGuard.Run(async () =>
        {
            using var caller = StackTools.Caller(session, owner, lane);
            return await operations.SetupAsync(owner, lane, slot, steps, tenants ?? [], renew, cancellationToken);
        });

    [McpServerTool(Name = "service_env", ReadOnly = true)]
    [Description("Shows the environment variables a running service was started with by octo-devstack (on top of the daemon's own), secret-looking " +
                 "values masked (password, secret, key, token, license, connection strings, credentials in URLs). Without lane/slot: the shared stack. Read-only.")]
    public ServiceEnvResult ServiceEnv(
        [Description("Service name.")] string service,
        [Description("Lane (octo-tools: feature environment; lane_list) whose stack runs the service; omit for the shared stack.")] string? lane = null,
        [Description("A named stack slot (stack_list), when no lane is given; default: the shared stack.")] string? slot = null) =>
        ToolGuard.Run(() => operations.ServiceEnv(lane, slot, service));

    [McpServerTool(Name = "stack_verify", ReadOnly = true)]
    [Description("Checks that a lane stack's data is its own: its system database (exists), the tenants registered in it with their database and " +
                 "ownership marker (AB#4945; a missing marker or another owner is a warning), tenant databases registered in another stack's system " +
                 "database too (both stacks would share the data), RabbitMQ queues and consumers with the stack's prefix and the service connections " +
                 "consuming them (consumerConnections: MassTransit connection name, processId, host and the stack's service the process belongs to - " +
                 "on Windows the service's own process below the cmd.exe wrapper, stack_status's processId, not its pid; a consumer on this machine " +
                 "that is no service of the stack - nor a child process of one - is a warning), CrateDB schemas <prefix>_<tenant>. slot='default' " +
                 "verifies the shared stack. Read-only.")]
    public Task<SlotVerifyResult> Verify(
        [Description(LaneDescription)] string? lane = null,
        [Description("A stack slot (stack_list) when no lane is given; 'default' is the shared stack.")] string? slot = null,
        CancellationToken cancellationToken = default) =>
        ToolGuard.Run(() => operations.VerifyAsync(lane, slot, cancellationToken));
}
