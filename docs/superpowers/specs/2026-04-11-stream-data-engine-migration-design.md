# Stream Data Engine Migration — Design Spec

**Date:** 2026-04-11
**Epic:** AB#3364 — Stream data version 2
**Scope:** Move stream data query/repository layer from asset-repo-services into the CK engine. Pure refactoring — no new features, no API changes.

## Problem

The stream data query layer currently lives in the wrong place. The GraphQL resolvers in `octo-asset-repo-services` contain ~1350 lines of business logic: query building, field resolution, pagination, operator mapping, and result transformation. This is the work that the engine's `ITenantRepository` does for runtime data — but for stream data, it's all stuffed into the GraphQL layer.

This means:
- Stream data queries can't use CK cache or engine tooling
- Query logic can't be reused outside GraphQL (e.g., pipeline nodes, CLI)
- The GraphQL layer is 10x thicker for stream data than for runtime data
- Duplicate enum/operator mapping code is scattered across DTO layers

## Goal

After this migration:
- `ITenantContext.GetStreamDataRepository()` returns an `IStreamDataRepository`
- All query orchestration lives in the engine, same as runtime data
- The GraphQL resolvers are thin wrappers (~30 lines each, same pattern as runtime data)
- One canonical set of enums for operators, aggregation types, sort directions
- All existing queries continue to work — verified by integration tests

## Architecture After Migration

```
GraphQL Layer (octo-asset-repo-services)
  ├── Thin resolver: extract args -> build options -> call repository -> map to GraphQL
  └── ~30 lines per resolver (same as runtime data today)
       |
       v
Engine Contracts (octo-construction-kit-engine)
  ├── IStreamDataRepository (query execution interface)
  ├── StreamDataQueryOptions (fluent builder API)
  ├── StreamDataPoint, StreamDataRow, StreamDataQueryResult (engine-level types)
  └── Canonical enums (StreamDataAggregationFunction, StreamDataFieldFilterOperator, etc.)
       |
       v
Engine Implementation (octo-construction-kit-engine-mongodb)
  ├── CrateDbStreamDataRepository (implements IStreamDataRepository)
  ├── Query orchestration: field resolution via CK cache, pagination, operator mapping
  ├── Wired into ITenantContext.GetStreamDataRepository()
  ├── CrateDB plumbing (moved from octo-common-services/StreamData):
  │   CrateQueryBuilder, CrateQueryCompiler, CrateDatabaseClient, connection management
  └── Health checks
```

## Layer Responsibilities

| Layer | Repo | What lives there |
|---|---|---|
| CK-aware contracts | `octo-construction-kit-engine` | `IStreamDataRepository`, query options, result types, canonical enums — new |
| CK-aware implementation + CrateDB plumbing | `octo-construction-kit-engine-mongodb` | `CrateDbStreamDataRepository`, CrateQueryBuilder/Compiler, CrateDatabaseClient, connection management, field resolution, pagination, operator mapping, tenant lifecycle — the entire StreamData assembly moves here from common-services |
| GraphQL thin wrapper | `octo-asset-repo-services` | Argument extraction, options building, result mapping to GraphQL types — rewritten to be thin |

## Engine Contracts (`octo-construction-kit-engine`)

Namespace: `Meshmakers.Octo.ConstructionKit.Runtime.Contracts.StreamData`

### IStreamDataRepository

```csharp
public interface IStreamDataRepository
{
    // Lifecycle
    Task EnsureDatabaseCreatedAsync();
    Task DeleteDatabaseAsync();

    // Data ingestion
    Task InsertAsync(StreamDataPoint datapoint);
    Task InsertAsync(IEnumerable<StreamDataPoint> datapoints);

    // Queries
    Task<StreamDataQueryResult> ExecuteQueryAsync(
        StreamDataQueryOptions options);

    Task<StreamDataQueryResult> ExecuteAggregationQueryAsync(
        StreamDataAggregationQueryOptions options);

    Task<StreamDataQueryResult> ExecuteGroupedAggregationQueryAsync(
        StreamDataGroupedAggregationQueryOptions options);

    Task<StreamDataQueryResult> ExecuteDownsamplingQueryAsync(
        StreamDataDownsamplingQueryOptions options);
}
```

### Query Options (Fluent Builder API)

```csharp
public class StreamDataQueryOptionsBase
{
    public RtCkId<CkTypeId> CkTypeId { get; }
    public IReadOnlyList<string> Columns { get; }
    public IReadOnlyList<OctoObjectId>? RtIds { get; }
    public DateTime? From { get; }
    public DateTime? To { get; }
    public int? Limit { get; }          // row cap
    public IReadOnlyList<StreamDataSortOrder>? SortOrders { get; }
    public IReadOnlyList<StreamDataFieldFilter>? FieldFilters { get; }
    public int? Offset { get; }         // pagination
    public int? PageSize { get; }       // pagination
}

public class StreamDataQueryOptions : StreamDataQueryOptionsBase
{
    public static StreamDataQueryOptions Create() => new();
    public StreamDataQueryOptions WithCkTypeId(RtCkId<CkTypeId> id) => ...;
    public StreamDataQueryOptions WithColumns(IReadOnlyList<string> columns) => ...;
    public StreamDataQueryOptions WithRtIds(IReadOnlyList<OctoObjectId>? ids) => ...;
    public StreamDataQueryOptions WithTimeRange(DateTime? from, DateTime? to) => ...;
    public StreamDataQueryOptions WithLimit(int? limit) => ...;
    public StreamDataQueryOptions WithSortOrders(IReadOnlyList<StreamDataSortOrder>? sorts) => ...;
    public StreamDataQueryOptions WithFieldFilters(IReadOnlyList<StreamDataFieldFilter>? filters) => ...;
    public StreamDataQueryOptions WithPagination(int? offset, int? pageSize) => ...;
}

public class StreamDataAggregationQueryOptions : StreamDataQueryOptionsBase
{
    // Inherits all base options + fluent methods
    public IReadOnlyList<StreamDataAggregationColumn> AggregationColumns { get; }
    public StreamDataAggregationQueryOptions WithAggregationColumns(...) => ...;
}

public class StreamDataGroupedAggregationQueryOptions : StreamDataAggregationQueryOptions
{
    public IReadOnlyList<string> GroupByColumns { get; }
    public StreamDataGroupedAggregationQueryOptions WithGroupByColumns(...) => ...;
}

public class StreamDataDownsamplingQueryOptions : StreamDataQueryOptionsBase
{
    public IReadOnlyList<StreamDataAggregationColumn> AggregationColumns { get; }
    public TimeSpan BinInterval { get; }
    public StreamDataDownsamplingQueryOptions WithAggregationColumns(...) => ...;
    public StreamDataDownsamplingQueryOptions WithBinInterval(TimeSpan interval) => ...;
}
```

### Canonical Enums

One source of truth — replaces duplicate enums across DTO layers:

```csharp
public enum StreamDataAggregationFunction
{
    Average, Minimum, Maximum, Count, Sum
}

public enum StreamDataFieldFilterOperator
{
    Equals, NotEquals,
    GreaterThan, GreaterThanOrEqual,
    LessThan, LessThanOrEqual,
    Like
}

public enum StreamDataSortDirection
{
    Ascending, Descending
}
```

### Engine-Level Types

Replace `DataPointDto` (from common-services) at the engine boundary:

```csharp
public class StreamDataPoint
{
    public OctoObjectId RtId { get; }
    public RtCkId<CkTypeId> CkTypeId { get; }
    public DateTime Timestamp { get; }
    public string? RtWellKnownName { get; }
    public IReadOnlyDictionary<string, object?> Attributes { get; }
}

public class StreamDataRow
{
    public OctoObjectId? RtId { get; }
    public RtCkId<CkTypeId>? CkTypeId { get; }
    public DateTime? Timestamp { get; }
    public string? RtWellKnownName { get; }
    public IReadOnlyDictionary<string, object?> Values { get; }
}

public class StreamDataQueryResult
{
    public IReadOnlyList<StreamDataRow> Rows { get; }
    public long TotalCount { get; }
}
```

### ITenantContext Extension

```csharp
// Added to existing ITenantContext interface
IStreamDataRepository? GetStreamDataRepository();
```

Returns null if stream data is not enabled for the tenant.

## Engine Implementation (`octo-construction-kit-engine-mongodb`)

Namespace: `Meshmakers.Octo.ConstructionKit.Runtime.Engine.CrateDb`

### CrateDbStreamDataRepository

Implements `IStreamDataRepository`. This is where the ~800 lines of business logic from the GraphQL resolvers move to:

- **Field resolution** — uses `ICkCacheService` to determine which fields are default vs data stream attributes. Replaces standalone `StreamDataFieldResolver`.
- **Query building** — creates `CrateQueryBuilder`, sets filters/columns/sorting/pagination. Currently done in GraphQL.
- **Pagination** — rowCap/offset/tiebreaker logic. Currently in `ExecutePaginatedStreamDataQueryAsync` in GraphQL.
- **Operator mapping** — engine enums to CrateDB SQL operators. Currently scattered across multiple methods.
- **Result transformation** — `DataPointDto` to `StreamDataRow`. Currently in GraphQL.
- **Empty bin detection** — for downsampling queries. Currently in GraphQL.

Delegates to `IStreamDataDatabaseClient` (now colocated in engine-mongodb after the StreamData assembly move) for actual SQL execution.

### Wiring into ITenantContext

```csharp
// In TenantContext (engine-mongodb)
public IStreamDataRepository? GetStreamDataRepository()
{
    if (!_streamDataEnabled) return null;

    _streamDataRepository ??= new CrateDbStreamDataRepository(
        _ckCacheService,
        _streamDataDatabaseClient,
        _streamDataDatabaseManagementClient,
        TenantId);

    return _streamDataRepository;
}
```

### DI Registration

```csharp
public static IRuntimeEngineBuilder AddCrateDbStreamDataRepository(
    this IRuntimeEngineBuilder builder)
{
    // All stream data services now registered from engine-mongodb
    builder.Services.AddSingleton<IStreamDataDatabaseClient, CrateDatabaseClient>();
    builder.Services.AddSingleton<IStreamDataDatabaseManagementClient, CrateDatabaseClient>();
    // ... connection access, health checks, etc.
    return builder;
}
```

Usage in `octo-asset-repo-services` startup:

```csharp
services.AddRuntimeEngine()
    .AddMongoDbRuntimeRepository()
    .AddCrateDbStreamDataRepository();  // new
```

### StreamData Assembly Move

The entire StreamData project moves from `octo-common-services/src/StreamData/` to `octo-construction-kit-engine-mongodb`. This includes:
- `CrateQueryBuilder`, `CrateQueryCompiler` — SQL query building
- `CrateDatabaseClient` — Dapper/Npgsql execution
- `CrateDbConnectionAccess` — connection pooling
- `StreamDataFieldResolver` — field name resolution (will be refactored to use CK cache)
- `StreamDataHealthCheck` — health check
- `DataPointDto` and related types — will be replaced by engine-level `StreamDataPoint`/`StreamDataRow`

The StreamData project's current dependency on `Infrastructure` (from common-services) becomes a PackageReference to `Meshmakers.Octo.Services.Infrastructure`.

**Downstream consumers update their references:**
- `octo-asset-repo-services` — changes from `Meshmakers.Octo.Services.StreamData` to the new engine-mongodb package
- `octo-mesh-adapter` — same update

### Tenant Lifecycle — Absorbed into Engine

Current `ITenantManager` and `IStreamDataTenantContext` from `octo-asset-repo-services` are absorbed:

- Enable/disable becomes configuration on `ITenantContext`
- Table creation: `CrateDbStreamDataRepository.EnsureDatabaseCreatedAsync()` called during tenant startup
- Table deletion: called during `DisableStreamData` or tenant deletion
- REST endpoints (`/streamdata/enable`, `/streamdata/disable`) remain but become thin — call `ITenantContext` methods

## GraphQL Layer After Migration (`octo-asset-repo-services`)

### Resolver Pattern (all 8 query types follow this)

```csharp
private async Task<object?> ResolveStreamDataQueryAsync(
    IResolveFieldContext context)
{
    var tenantRepo = context.GetTenantRepository();
    var streamDataRepo = context.GetStreamDataRepository();

    // 1. Load persisted query entity
    var queryEntity = await tenantRepo
        .GetRtEntityByRtIdAsync<RtStreamDataSimpleQuery>(session, queryId);

    // 2. Build options from entity + runtime args
    var options = StreamDataQueryOptions.Create()
        .WithCkTypeId(queryEntity.CkTypeId)
        .WithColumns(queryEntity.Columns)
        .WithRtIds(queryEntity.RtIds)
        .WithTimeRange(queryEntity.From, queryEntity.To)
        .WithLimit(queryEntity.Limit)
        .WithFieldFilters(StreamDataGraphQlMapper.MapFilters(queryEntity.FieldFilters))
        .WithSortOrders(runtimeSortOrder ?? StreamDataGraphQlMapper.MapSorts(queryEntity.Sorting))
        .WithPagination(offset, pageSize);

    // 3. Execute
    var result = await streamDataRepo.ExecuteQueryAsync(options);

    // 4. Map to GraphQL
    return StreamDataGraphQlMapper.BuildConnection(result, offset, pageSize);
}
```

### Consolidated Mapper

One static helper class replaces scattered mapping methods:

```csharp
internal static class StreamDataGraphQlMapper
{
    // GraphQL enum -> Engine enum (one mapping per enum)
    static StreamDataFieldFilterOperator MapOperator(...)
    static StreamDataSortDirection MapSortDirection(...)
    static StreamDataAggregationFunction MapAggregation(...)

    // Engine result -> GraphQL type
    static StreamDataQueryRowDtoType MapRow(StreamDataRow row)

    // Connection builder
    static Connection<StreamDataQueryRowDtoType> BuildConnection(
        StreamDataQueryResult result, int? offset, int? pageSize)
}
```

### What Gets Deleted

- All `CrateQueryBuilder` / `CrateQueryCompiler` usage in GraphQL — gone
- `StreamDataFieldResolver` instantiation — gone
- Pagination math (rowCap, offset, tiebreaker) — moved to engine
- Duplicate operator mapping methods — consolidated
- `ITenantManager`, `IStreamDataTenantContext`, `IStreamDataTenantContextFactory` — gone
- ~1100 lines removed from `StreamDataQuery.cs`

## Migration Phases

Each phase produces a working system. Queries work throughout.

### Phase 1: Test Harness

**Goal:** Safety net before any refactoring.

Write integration tests for all 8 existing GraphQL stream data endpoints (4 persisted + 4 transient) in `octo-asset-repo-services`:
- Testcontainers for both MongoDB and CrateDB
- Hit the GraphQL API through the actual resolver stack
- Test cases per query type: basic query, time range filtering, field filters, sort order, pagination, empty result sets
- These tests do NOT change during the migration — they validate external behavior

### Phase 2: Move StreamData Assembly + Engine Contracts

**Goal:** Move the CrateDB plumbing into engine-mongodb and define the target interfaces.

Move StreamData from `octo-common-services` to `octo-construction-kit-engine-mongodb`:
- Move `CrateQueryBuilder`, `CrateQueryCompiler`, `CrateDatabaseClient`, `CrateDbConnectionAccess`, health checks
- Update the project's dependency on `Infrastructure` from ProjectReference to PackageReference
- Update downstream consumers (`octo-asset-repo-services`, `octo-mesh-adapter`) to reference the new package
- Verify existing tests still pass after the move

In `octo-construction-kit-engine` (contracts):
- `IStreamDataRepository` interface
- `StreamDataQueryOptions` fluent builder (and aggregation/grouped/downsampling variants)
- `StreamDataPoint`, `StreamDataRow`, `StreamDataQueryResult`
- Canonical enums (`StreamDataAggregationFunction`, `StreamDataFieldFilterOperator`, `StreamDataSortDirection`)
- Supporting types (`StreamDataSortOrder`, `StreamDataFieldFilter`, `StreamDataAggregationColumn`)
- Extend `ITenantContext` with `GetStreamDataRepository()`

### Phase 3: Engine Implementation

**Goal:** Build the repository that absorbs the GraphQL business logic.

In `octo-construction-kit-engine-mongodb`:
- `CrateDbStreamDataRepository` implementing `IStreamDataRepository`
- Move query orchestration from GraphQL: field resolution, query building, pagination, operator mapping, result transformation, empty bin detection
- Wire into `ITenantContext` (lazy instantiation)
- DI registration: `AddCrateDbStreamDataRepository()` extension
- Move tenant lifecycle (enable/disable, table management) into engine
- Engine-level integration tests with Testcontainers CrateDB

### Phase 4: Thin Out GraphQL

**Goal:** Rewrite resolvers to use the engine repository.

In `octo-asset-repo-services`:
- Rewrite all 8 resolvers to the thin pattern (extract args -> build options -> call repository -> map to GraphQL)
- Create `StreamDataGraphQlMapper` with consolidated enum mapping + result mapping
- Remove all CrateQueryBuilder/Compiler/FieldResolver usage
- Verify Phase 1 integration tests still pass

### Phase 5: Cleanup

**Goal:** Remove dead code.

- Delete `ITenantManager`, `IStreamDataTenantContext`, `IStreamDataTenantContextFactory` from `octo-asset-repo-services`
- Delete the old `StreamData` project from `octo-common-services` (already moved in Phase 2)
- Remove any dead mapping code, unused DTOs
- Remove old `StreamData.Tests` from common-services (tests moved to engine-mongodb)
- Verify all tests pass

## What Does NOT Change

- CK model types (StreamDataSimpleQuery, StreamDataAggregationQuery, etc.)
- CrateDB table schema
- GraphQL API contract (same queries, same arguments, same results)
- REST endpoints for enable/disable (only their implementation thins out)
- Build order — no dependency direction changes. StreamData moves from common-services (step 6) to engine-mongodb (step 5), which is earlier in the chain. Downstream consumers already depend on engine-mongodb transitively.
