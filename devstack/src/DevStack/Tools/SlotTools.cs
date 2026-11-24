using System.ComponentModel;
using Meshmakers.Octo.DevStack.Configuration;
using Meshmakers.Octo.DevStack.Runtime;
using ModelContextProtocol.Server;

namespace Meshmakers.Octo.DevStack.Tools;

/// <summary>A stack in stack_list: its slot summary, the ports of every configured service in it and its derived values.</summary>
public sealed record SlotListEntry(
    SlotSummary Slot,
    IReadOnlyDictionary<string, IReadOnlyList<int>> Ports,
    IReadOnlyDictionary<string, string> Derived,
    IReadOnlyList<string> SharedStackOnly);

/// <summary>The stacks of this machine and the retired slot indices.</summary>
[McpServerToolType]
public sealed class SlotTools(StackSupervisor supervisor, ConfigStore store, SlotDataCleanup cleanup, ILogger<SlotTools>? logger = null)
{
    [McpServerTool(Name = "stack_list", ReadOnly = true)]
    [Description("Lists the stacks of this machine and what keeps them apart: the shared stack (slot 'default', the configured ports) and every lane " +
                 "stack or named slot (devstack.yaml 'slots' or created by its first stack_start) with index, port offset, prefix, whether it runs, " +
                 "from which lane, lease holder, profile, n/m healthy, the ports of every configured service in it, the derived values (system " +
                 "database, instance prefixes, storage folders, service URLs), the generated files (identity overlay, octo-cli installation entry) and " +
                 "the last setup (setup: every step's outcome, see stack_setup). Read-only.")]
    public Task<List<SlotListEntry>> List() =>
        ToolGuard.Run(async () =>
        {
            var config = store.Load();
            var exclusive = config.Services.Keys.Where(n => SlotRules.IsExclusive(config, n)).ToList();
            var result = new List<SlotListEntry>();
            foreach (var summary in await supervisor.SummariesAsync())
            {
                var slot = new SlotInfo(summary.Name, summary.Index, summary.PortOffset, summary.Prefix);
                var derivation = SlotDeriver.Apply(config, slot, SlotDeriver.SlotDirectory(supervisor.StateDirectory, slot));
                var ports = derivation.Config.Services
                    .Where(s => s.Value.Ports.Count > 0 && (slot.IsDefault || !exclusive.Contains(s.Key)))
                    .ToDictionary(s => s.Key, s => (IReadOnlyList<int>)s.Value.Ports);
                result.Add(new SlotListEntry(summary, ports, derivation.Rows.ToDictionary(r => r.Id, r => r.Value), exclusive));
            }

            return result;
        });

    [McpServerTool(Name = "admin_slot_retired", ReadOnly = true)]
    [Description("Lists the retired slot indices (admin): the stacks of removed lanes whose data may still exist - lane_remove with keepData=true, a " +
                 "data drop with a failed step, or a lane removed before the daemon dropped data itself. No new stack gets a retired index. Every " +
                 "entry lists the leftovers (system database, RabbitMQ/CrateDB/artifact prefixes, folders) with the command to drop each by hand; " +
                 "admin_slot_drop_data drops them. Read-only.")]
    public Dictionary<int, RetiredSlot> Retired() => ToolGuard.Run(() => supervisor.RetiredSlots());

    [McpServerTool(Name = "admin_slot_drop_data", Destructive = true)]
    [Description("Drops the data of a retired slot index and frees the index (admin, only on the developer's go): what lane_remove drops after a " +
                 "removal - system, tenant and Hangfire databases, RabbitMQ queues and exchanges with its prefix, CrateDB schemas, the octo-cli " +
                 "installation entry and contexts, its state folder, the lane's secret files - for a lane removed with keepData=true, before this " +
                 "existed, or whose drop had a failed step. Tenant databases another stack registers or owns are kept. Every step reports what it " +
                 "dropped; when every step succeeded the index is free again, otherwise it stays retired with the remaining leftovers. S3 artifacts " +
                 "are only listed. Refused while a stack uses the index or anything listens on its shifted ports.")]
    public Task<SlotDataDrop> DropData(
        [Description(StackTools.OwnerDescription)] string owner,
        [Description("The retired index (admin_slot_retired).")] int index,
        [Description(StackTools.SessionDescription)] string? session = null,
        CancellationToken cancellationToken = default) =>
        ToolGuard.Run(() => cleanup.DropRetiredAsync(owner, index, session, cancellationToken));

    [McpServerTool(Name = "admin_slot_forget", Destructive = true)]
    [Description("Frees a retired slot index without dropping anything (admin, only on the developer's go): only after the developer confirmed " +
                 "that its leftovers (admin_slot_retired) are dropped by hand - a new stack with that index would use the same names and find the old " +
                 "data; admin_slot_drop_data drops them and frees the index itself. Requires confirmDataDropped=true; refused while a stack uses the " +
                 "index or anything listens on its shifted ports.")]
    public Task<RetiredSlot> Forget(
        [Description(StackTools.OwnerDescription + " Logged.")] string owner,
        [Description("The retired index (admin_slot_retired).")] int index,
        [Description("true only when the developer confirmed the leftovers of this index are dropped.")] bool confirmDataDropped = false,
        [Description(StackTools.SessionDescription)] string? session = null,
        CancellationToken cancellationToken = default) =>
        ToolGuard.Run(async () =>
        {
            // Under the drop gate: a running admin_slot_drop_data / lane_remove drop of this index ends first.
            var freed = await cleanup.ForgetAsync(index, confirmDataDropped, cancellationToken);
            logger?.LogInformation("{Owner} ({Session}) freed the retired slot index {Index}", owner, session ?? "-", index);
            return freed;
        });
}
