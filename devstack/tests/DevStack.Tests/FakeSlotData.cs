using Meshmakers.Octo.DevStack.Runtime;

namespace Meshmakers.Octo.DevStack.Tests;

/// <summary>
///     The stores of a lane stack's data drop as lists in memory: MongoDB databases with their tenant registries and ownership
///     markers, RabbitMQ queues and exchanges, CrateDB tables, octo-cli contexts and installation entries. Tests never touch
///     the real databases, the broker, ~/.octo-cli or installations.json.
/// </summary>
internal sealed class FakeSlotData
{
    public FakeMongo Mongo { get; } = new();
    public FakeRabbit Rabbit { get; } = new();
    public FakeCrate Crate { get; } = new();
    public FakeOctoCli OctoCli { get; } = new();

    public SlotDataStores Stores => new(_ => Mongo, _ => Rabbit, _ => Crate, _ => OctoCli);

    internal sealed class FakeMongo : IMongoSlotData
    {
        public List<string> Databases { get; } = [];
        public Dictionary<string, List<InventoryTenant>> Tenants { get; } = new(StringComparer.Ordinal);
        public Dictionary<string, string> Owners { get; } = new(StringComparer.Ordinal);
        public HashSet<string> FailDrop { get; } = new(StringComparer.Ordinal);
        public List<string> Dropped { get; } = [];
        public bool Unreachable { get; set; }

        /// <summary>An error no step expects (a bug of a store): lane_remove still answers, the index stays retired.</summary>
        public Exception? Unexpected { get; set; }

        private void Check()
        {
            if (Unexpected != null)
            {
                throw Unexpected;
            }

            if (Unreachable)
            {
                throw new TimeoutException("A timeout occurred after 5000ms selecting a server.");
            }
        }

        public Task<IReadOnlyList<string>> DatabasesAsync(CancellationToken cancellationToken)
        {
            Check();
            return Task.FromResult<IReadOnlyList<string>>(Databases.ToList());
        }

        public Task<IReadOnlyList<InventoryTenant>> TenantsAsync(string systemDatabase, CancellationToken cancellationToken)
        {
            Check();
            return Task.FromResult<IReadOnlyList<InventoryTenant>>(Databases.Contains(systemDatabase) ? Tenants.GetValueOrDefault(systemDatabase) ?? [] : []);
        }

        public Task<string?> OwnerAsync(string database, CancellationToken cancellationToken)
        {
            Check();
            return Task.FromResult(Owners.GetValueOrDefault(database));
        }

        public Task DropDatabaseAsync(string database, CancellationToken cancellationToken)
        {
            Check();
            if (FailDrop.Contains(database))
            {
                throw new MongoDB.Driver.MongoClientException($"not authorized on {database} to execute command {{ dropDatabase: 1 }}");
            }

            Databases.Remove(database);
            Dropped.Add(database);
            return Task.CompletedTask;
        }
    }

    internal sealed class FakeRabbit : IRabbitSlotData
    {
        public List<BrokerObject> Queues { get; } = [];
        public List<BrokerObject> Exchanges { get; } = [];
        public List<string> Deleted { get; } = [];
        public bool Unreachable { get; set; }

        private void Check()
        {
            if (Unreachable)
            {
                throw new HttpRequestException("No connection could be made because the target machine actively refused it. (localhost:15672)");
            }
        }

        public Task<IReadOnlyList<BrokerObject>> QueuesAsync(CancellationToken cancellationToken)
        {
            Check();
            return Task.FromResult<IReadOnlyList<BrokerObject>>(Queues.ToList());
        }

        public Task<IReadOnlyList<BrokerObject>> ExchangesAsync(CancellationToken cancellationToken)
        {
            Check();
            return Task.FromResult<IReadOnlyList<BrokerObject>>(Exchanges.ToList());
        }

        public Task DeleteQueueAsync(BrokerObject queue, CancellationToken cancellationToken)
        {
            Check();
            Queues.Remove(queue);
            Deleted.Add("queue " + queue.Name);
            return Task.CompletedTask;
        }

        public Task DeleteExchangeAsync(BrokerObject exchange, CancellationToken cancellationToken)
        {
            Check();
            Exchanges.Remove(exchange);
            Deleted.Add("exchange " + exchange.Name);
            return Task.CompletedTask;
        }
    }

    internal sealed class FakeCrate : ICrateSlotData
    {
        public List<CrateRelation> Relations { get; } = [];
        public List<string> Dropped { get; } = [];
        public bool Unreachable { get; set; }

        public Task<IReadOnlyList<CrateRelation>> RelationsAsync(CancellationToken cancellationToken) =>
            Unreachable
                ? throw new HttpRequestException("No connection could be made (localhost:4301)")
                : Task.FromResult<IReadOnlyList<CrateRelation>>(Relations.ToList());

        public Task DropAsync(CrateRelation relation, CancellationToken cancellationToken)
        {
            Relations.Remove(relation);
            Dropped.Add(relation.ToString());
            return Task.CompletedTask;
        }
    }

    internal sealed class FakeOctoCli : IOctoCliSlotData
    {
        public List<string>? ContextNames { get; set; } = [];
        public List<string> Installations { get; } = [];
        public List<string> Removed { get; } = [];
        public HashSet<string> FailContexts { get; } = new(StringComparer.Ordinal);

        public IReadOnlyList<string>? Contexts() => ContextNames?.ToList();

        public Task<IReadOnlyDictionary<string, string?>> RemoveContextsAsync(IReadOnlyList<string> names, CancellationToken cancellationToken)
        {
            var result = new Dictionary<string, string?>(StringComparer.Ordinal);
            foreach (var name in names)
            {
                if (FailContexts.Contains(name))
                {
                    result[name] = "exit 1: Context is locked";
                    continue;
                }

                ContextNames?.Remove(name);
                Removed.Add("context " + name);
                result[name] = null;
            }

            return Task.FromResult<IReadOnlyDictionary<string, string?>>(result);
        }

        public (bool Removed, string File, string? Backup) RemoveInstallation(string name)
        {
            var removed = Installations.Remove(name);
            if (removed)
            {
                Removed.Add("installation " + name);
            }

            return (removed, "/fake/installations.json", removed ? "/fake/installations.json.bak-1" : null);
        }
    }
}
