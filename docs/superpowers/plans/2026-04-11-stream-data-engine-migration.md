# Stream Data Engine Migration — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move the stream data query/repository layer from `octo-asset-repo-services` into the CK engine, keeping all existing queries working throughout.

**Architecture:** Stream data gets a proper engine-level repository (`IStreamDataRepository`) accessed via `ITenantContext.GetStreamDataRepository()`. The CrateDB plumbing (query builder, compiler, database client) moves from `octo-common-services` into `octo-construction-kit-engine-mongodb`. GraphQL resolvers become thin wrappers.

**Tech Stack:** C# / .NET 10, CrateDB (via Dapper/Npgsql), MongoDB, GraphQL.NET, xUnit, Testcontainers

**Spec:** `docs/superpowers/specs/2026-04-11-stream-data-engine-migration-design.md`

---

## File Structure

### New files in `octo-construction-kit-engine`

| File | Responsibility |
|---|---|
| `src/Runtime.Contracts/StreamData/IStreamDataRepository.cs` | Repository interface — query execution, data ingestion, lifecycle |
| `src/Runtime.Contracts/StreamData/StreamDataQueryOptions.cs` | Fluent builder for simple queries |
| `src/Runtime.Contracts/StreamData/StreamDataAggregationQueryOptions.cs` | Fluent builder for aggregation queries |
| `src/Runtime.Contracts/StreamData/StreamDataGroupedAggregationQueryOptions.cs` | Fluent builder for grouped aggregation queries |
| `src/Runtime.Contracts/StreamData/StreamDataDownsamplingQueryOptions.cs` | Fluent builder for downsampling queries |
| `src/Runtime.Contracts/StreamData/StreamDataPoint.cs` | Engine-level data point for ingestion |
| `src/Runtime.Contracts/StreamData/StreamDataRow.cs` | Engine-level result row |
| `src/Runtime.Contracts/StreamData/StreamDataQueryResult.cs` | Query result container (rows + total count) |
| `src/Runtime.Contracts/StreamData/StreamDataEnums.cs` | Canonical enums: `StreamDataAggregationFunction`, `StreamDataFieldFilterOperator`, `StreamDataSortDirection` |
| `src/Runtime.Contracts/StreamData/StreamDataSortOrder.cs` | Sort order value object |
| `src/Runtime.Contracts/StreamData/StreamDataFieldFilter.cs` | Field filter value object |
| `src/Runtime.Contracts/StreamData/StreamDataAggregationColumn.cs` | Aggregation column value object |

### New files in `octo-construction-kit-engine-mongodb`

| File | Responsibility |
|---|---|
| `src/Runtime.Engine.MongoDb/StreamData/CrateDbStreamDataRepository.cs` | `IStreamDataRepository` implementation — query orchestration, field resolution, pagination |
| `src/Runtime.Engine.MongoDb/Configuration/DependencyInjection/StreamDataEngineBuilderExtensions.cs` | `AddCrateDbStreamDataRepository()` DI extension |

### Moved files (from `octo-common-services/src/StreamData/` to `octo-construction-kit-engine-mongodb/src/Runtime.Engine.MongoDb/StreamData/`)

All files from the StreamData assembly move. Key ones:

| Original | New location in engine-mongodb |
|---|---|
| `Client/CrateDatabaseClient.cs` | `StreamData/Client/CrateDatabaseClient.cs` |
| `Client/CrateDbClientAccess.cs` | `StreamData/Client/CrateDbClientAccess.cs` |
| `QueryBuilder/CrateQueryBuilder.cs` | `StreamData/QueryBuilder/CrateQueryBuilder.cs` |
| `QueryBuilder/CrateQueryCompiler.cs` | `StreamData/QueryBuilder/CrateQueryCompiler.cs` |
| `StreamDataFieldResolver.cs` | `StreamData/StreamDataFieldResolver.cs` |
| `IStreamDataDatabaseClient.cs` | `StreamData/IStreamDataDatabaseClient.cs` |
| (all other files) | (same relative structure under `StreamData/`) |

### Modified files

| File | Change |
|---|---|
| `octo-construction-kit-engine-mongodb/src/Runtime.Contracts.MongoDb/ITenantContext.cs` | Add `GetStreamDataRepository()` |
| `octo-construction-kit-engine-mongodb/src/Runtime.Engine.MongoDb/TenantContext.cs` | Implement `GetStreamDataRepository()` |
| `octo-construction-kit-engine-mongodb/src/Runtime.Engine.MongoDb/Runtime.Engine.MongoDb.csproj` | Add Dapper, Npgsql, Infrastructure PackageReference |
| `octo-asset-repo-services/src/AssetRepositoryServices/GraphQL/StreamDataQuery.cs` | Rewrite to thin resolvers |
| `octo-asset-repo-services/src/AssetRepositoryServices/Program.cs` | Replace `AddStreamDataManagement()` + `AddStreamDataDatabase()` with `AddCrateDbStreamDataRepository()` |
| `octo-asset-repo-services/src/AssetRepositoryServices/AssetRepositoryServices.csproj` | Remove `Meshmakers.Octo.Services.StreamData` reference |
| `octo-mesh-adapter/src/MeshAdapter.Sdk/MeshAdapter.Sdk.csproj` | Remove `Meshmakers.Octo.Services.StreamData` reference |

### Deleted files (Phase 5)

| File | Reason |
|---|---|
| `octo-asset-repo-services/.../StreamData/Services/TenantManager.cs` | Absorbed into engine |
| `octo-asset-repo-services/.../StreamData/Services/StreamDataTenantContext.cs` | Absorbed into engine |
| `octo-asset-repo-services/.../StreamData/Services/TimeSeriesTenantContextFactory.cs` | Absorbed into engine |
| `octo-asset-repo-services/.../StreamData/ServiceCollectionExtensions.cs` | Replaced by engine DI |
| `octo-common-services/src/StreamData/` (entire directory) | Moved to engine-mongodb |
| `octo-common-services/tests/StreamData.Tests/` (entire directory) | Moved to engine-mongodb |

---

## Phase 1: Test Harness

### Task 1: Add CrateDB test fixture to asset-repo integration tests

**Files:**
- Create: `octo-asset-repo-services/tests/AssetRepositoryServices.IntegrationTests/StreamData/StreamDataTestFixture.cs`
- Modify: `octo-asset-repo-services/tests/AssetRepositoryServices.IntegrationTests/AssetRepositoryServices.IntegrationTests.csproj`

This fixture provides a CrateDB + MongoDB + full service stack for stream data integration tests. It creates a tenant, enables stream data, imports the System CK model, and inserts test data points.

- [ ] **Step 1: Add Testcontainers.CrateDb NuGet package**

Add to `AssetRepositoryServices.IntegrationTests.csproj`:

```xml
<PackageReference Include="Testcontainers.CrateDb" Version="4.5.0" />
```

If there's no CrateDB-specific Testcontainers package, use the generic container:

```xml
<PackageReference Include="Testcontainers" Version="4.5.0" />
```

- [ ] **Step 2: Create `StreamDataTestFixture.cs`**

This fixture:
1. Starts MongoDB (reuse existing `DatabaseFixture` pattern) and CrateDB Testcontainers
2. Boots a minimal service provider with runtime engine + stream data + CK models
3. Creates a tenant, enables stream data (creates CrateDB table)
4. Imports the System CK model (so we have StreamDataSimpleQuery etc.)
5. Inserts known test data points (e.g., 20 rows with timestamps spanning an hour, with attributes like `Voltage` and `Current`)
6. Exposes: `ITenantContext`, `IStreamDataDatabaseClient`, `TenantId`, and a GraphQL `IDocumentExecuter`

Follow the existing `DatabaseFixture` pattern in `octo-asset-repo-services/tests/AssetRepositoryServices.IntegrationTests/Fixtures/DatabaseFixture.cs`.

- [ ] **Step 3: Verify fixture starts and tears down cleanly**

Run: `dotnet test -c DebugL --filter "FullyQualifiedName~StreamDataTestFixture" octo-asset-repo-services/tests/AssetRepositoryServices.IntegrationTests/`

Expected: fixture starts containers, creates data, disposes cleanly. No tests yet — just verify the fixture lifecycle.

- [ ] **Step 4: Commit**

```
AB#3364: Add CrateDB test fixture for stream data integration tests
```

---

### Task 2: Write integration tests for simple stream data queries

**Files:**
- Create: `octo-asset-repo-services/tests/AssetRepositoryServices.IntegrationTests/StreamData/StreamDataSimpleQueryTests.cs`

These tests exercise the existing `StreamDataQuery` GraphQL resolver — they are the safety net that must keep passing throughout the migration.

- [ ] **Step 1: Write test class with fixture**

```csharp
public class StreamDataSimpleQueryTests : IClassFixture<StreamDataTestFixture>
{
    private readonly StreamDataTestFixture _fixture;

    public StreamDataSimpleQueryTests(StreamDataTestFixture fixture)
    {
        _fixture = fixture;
    }
}
```

- [ ] **Step 2: Write test — transient simple query returns expected rows**

Test that a `TransientStreamDataQuery` with columns `["Voltage", "Current"]` returns the test data points with correct values.

- [ ] **Step 3: Write test — time range filtering**

Test that a transient query with `from`/`to` filtering returns only rows within the time range.

- [ ] **Step 4: Write test — field filter (equals)**

Test that a transient query with a field filter `Voltage = <known_value>` returns only matching rows.

- [ ] **Step 5: Write test — sort order**

Test that a transient query with `sortOrder: [{attributePath: "Voltage", sortOrder: ASCENDING}]` returns rows in the correct order.

- [ ] **Step 6: Write test — pagination (first/after)**

Test that requesting `first: 5` returns 5 rows with correct `totalCount` and `hasNextPage`.

- [ ] **Step 7: Write test — persisted simple query**

Create a `StreamDataSimpleQuery` runtime entity, then execute it via the `StreamDataQuery` GraphQL endpoint. Verify it returns the same results as the equivalent transient query.

- [ ] **Step 8: Run all tests to verify they pass**

Run: `dotnet test -c DebugL --filter "FullyQualifiedName~StreamDataSimpleQueryTests" octo-asset-repo-services/tests/AssetRepositoryServices.IntegrationTests/`

Expected: All tests PASS.

- [ ] **Step 9: Commit**

```
AB#3364: Add integration tests for simple stream data queries
```

---

### Task 3: Write integration tests for aggregation and downsampling queries

**Files:**
- Create: `octo-asset-repo-services/tests/AssetRepositoryServices.IntegrationTests/StreamData/StreamDataAggregationQueryTests.cs`
- Create: `octo-asset-repo-services/tests/AssetRepositoryServices.IntegrationTests/StreamData/StreamDataDownsamplingQueryTests.cs`

- [ ] **Step 1: Write aggregation test — transient AVG aggregation returns correct result**

- [ ] **Step 2: Write aggregation test — grouped aggregation groups by CkTypeId**

- [ ] **Step 3: Write aggregation test — persisted aggregation query**

- [ ] **Step 4: Write downsampling test — transient downsampling with time bins**

- [ ] **Step 5: Write downsampling test — empty bins are detected**

- [ ] **Step 6: Write downsampling test — persisted downsampling query**

- [ ] **Step 7: Run all stream data tests**

Run: `dotnet test -c DebugL --filter "FullyQualifiedName~StreamData" octo-asset-repo-services/tests/AssetRepositoryServices.IntegrationTests/`

Expected: All tests PASS.

- [ ] **Step 8: Commit**

```
AB#3364: Add integration tests for aggregation and downsampling stream data queries
```

---

## Phase 2: Move StreamData Assembly + Engine Contracts

### Task 4: Move StreamData assembly from common-services to engine-mongodb

**Files:**
- Move: entire `octo-common-services/src/StreamData/` → `octo-construction-kit-engine-mongodb/src/Runtime.Engine.MongoDb/StreamData/`
- Modify: `octo-construction-kit-engine-mongodb/src/Runtime.Engine.MongoDb/Runtime.Engine.MongoDb.csproj`
- Delete: `octo-common-services/src/StreamData/StreamData.csproj` (the standalone project)

The moved files become part of the `Runtime.Engine.MongoDb` project — NOT a separate project within engine-mongodb. This keeps the NuGet package output simple.

- [ ] **Step 1: Copy all StreamData source files**

Copy `octo-common-services/src/StreamData/` contents (except `.csproj`) into `octo-construction-kit-engine-mongodb/src/Runtime.Engine.MongoDb/StreamData/`. Preserve the directory structure.

- [ ] **Step 2: Update namespaces**

Change the root namespace from `Meshmakers.Octo.Services.StreamData` to `Meshmakers.Octo.Runtime.Engine.MongoDb.StreamData` in all moved files. The internal structure stays the same:
- `Meshmakers.Octo.Runtime.Engine.MongoDb.StreamData.Client`
- `Meshmakers.Octo.Runtime.Engine.MongoDb.StreamData.QueryBuilder`
- `Meshmakers.Octo.Runtime.Engine.MongoDb.StreamData.Dtos`
- etc.

- [ ] **Step 3: Add Dapper and Npgsql to engine-mongodb .csproj**

Add to `Runtime.Engine.MongoDb.csproj`:

```xml
<PackageReference Include="Dapper" Version="2.1.72" />
<PackageReference Include="Npgsql" Version="10.0.2" />
```

Also add the Infrastructure package reference (previously a ProjectReference in common-services):

```xml
<PackageReference Include="Meshmakers.Octo.Services.Infrastructure" Version="$(OctoVersion)" />
```

- [ ] **Step 4: Verify engine-mongodb compiles**

Run: `dotnet build -c DebugL octo-construction-kit-engine-mongodb/`

Expected: Build succeeds. Fix any namespace or reference issues.

- [ ] **Step 5: Commit**

```
AB#3364: Move StreamData assembly from common-services to engine-mongodb
```

---

### Task 5: Update downstream consumers

**Files:**
- Modify: `octo-asset-repo-services/src/AssetRepositoryServices/AssetRepositoryServices.csproj`
- Modify: `octo-mesh-adapter/src/MeshAdapter.Sdk/MeshAdapter.Sdk.csproj`
- Modify: all `using Meshmakers.Octo.Services.StreamData` statements in both repos

- [ ] **Step 1: Update asset-repo package reference**

In `AssetRepositoryServices.csproj`, remove:

```xml
<PackageReference Include="Meshmakers.Octo.Services.StreamData" Version="$(OctoVersion)" />
```

The stream data types now come from `Meshmakers.Octo.Runtime.Engine.MongoDb` which is already referenced.

- [ ] **Step 2: Update asset-repo using statements**

Find and replace all `using Meshmakers.Octo.Services.StreamData` with `using Meshmakers.Octo.Runtime.Engine.MongoDb.StreamData` (and sub-namespaces) in `octo-asset-repo-services/src/`.

- [ ] **Step 3: Update mesh-adapter package reference and usings**

Same changes in `octo-mesh-adapter/src/MeshAdapter.Sdk/`.

- [ ] **Step 4: Verify both repos compile**

Run builds for both repos.

Expected: Both compile. Fix any remaining namespace issues.

- [ ] **Step 5: Commit**

```
AB#3364: Update asset-repo and mesh-adapter to use StreamData from engine-mongodb
```

---

### Task 6: Move StreamData tests from common-services to engine-mongodb

**Files:**
- Move: `octo-common-services/tests/StreamData.Tests/` → `octo-construction-kit-engine-mongodb/tests/StreamData.Tests/`
- Modify: test `.csproj` references and namespaces

- [ ] **Step 1: Copy test files and update references**

Copy `CrateQueryBuilderTests.cs` and `StreamDataFieldResolverTests.cs`. Update the `.csproj` to reference the `Runtime.Engine.MongoDb` project instead of the old `StreamData.csproj`. Update namespaces.

- [ ] **Step 2: Verify tests pass**

Run: `dotnet test -c DebugL octo-construction-kit-engine-mongodb/tests/StreamData.Tests/`

Expected: All existing tests PASS.

- [ ] **Step 3: Commit**

```
AB#3364: Move StreamData tests to engine-mongodb
```

---

### Task 7: Add engine contracts — IStreamDataRepository, types, and enums

**Files:**
- Create: `octo-construction-kit-engine/src/Runtime.Contracts/StreamData/IStreamDataRepository.cs`
- Create: `octo-construction-kit-engine/src/Runtime.Contracts/StreamData/StreamDataPoint.cs`
- Create: `octo-construction-kit-engine/src/Runtime.Contracts/StreamData/StreamDataRow.cs`
- Create: `octo-construction-kit-engine/src/Runtime.Contracts/StreamData/StreamDataQueryResult.cs`
- Create: `octo-construction-kit-engine/src/Runtime.Contracts/StreamData/StreamDataEnums.cs`
- Create: `octo-construction-kit-engine/src/Runtime.Contracts/StreamData/StreamDataSortOrder.cs`
- Create: `octo-construction-kit-engine/src/Runtime.Contracts/StreamData/StreamDataFieldFilter.cs`
- Create: `octo-construction-kit-engine/src/Runtime.Contracts/StreamData/StreamDataAggregationColumn.cs`

- [ ] **Step 1: Create canonical enums**

In `StreamDataEnums.cs`:

```csharp
namespace Meshmakers.Octo.Runtime.Contracts.StreamData;

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

- [ ] **Step 2: Create supporting value objects**

`StreamDataSortOrder.cs`:

```csharp
namespace Meshmakers.Octo.Runtime.Contracts.StreamData;

public class StreamDataSortOrder
{
    public required string AttributePath { get; init; }
    public StreamDataSortDirection Direction { get; init; }
}
```

`StreamDataFieldFilter.cs`:

```csharp
namespace Meshmakers.Octo.Runtime.Contracts.StreamData;

public class StreamDataFieldFilter
{
    public required string AttributePath { get; init; }
    public StreamDataFieldFilterOperator Operator { get; init; }
    public required object? Value { get; init; }
}
```

`StreamDataAggregationColumn.cs`:

```csharp
namespace Meshmakers.Octo.Runtime.Contracts.StreamData;

public class StreamDataAggregationColumn
{
    public required string AttributePath { get; init; }
    public StreamDataAggregationFunction Function { get; init; }
}
```

- [ ] **Step 3: Create engine-level data types**

`StreamDataPoint.cs`:

```csharp
using Meshmakers.Octo.ConstructionKit.Contracts;

namespace Meshmakers.Octo.Runtime.Contracts.StreamData;

public class StreamDataPoint
{
    public required OctoObjectId RtId { get; init; }
    public required RtCkId<CkTypeId> CkTypeId { get; init; }
    public required DateTime Timestamp { get; init; }
    public string? RtWellKnownName { get; init; }
    public IReadOnlyDictionary<string, object?> Attributes { get; init; }
        = new Dictionary<string, object?>();
}
```

`StreamDataRow.cs`:

```csharp
using Meshmakers.Octo.ConstructionKit.Contracts;

namespace Meshmakers.Octo.Runtime.Contracts.StreamData;

public class StreamDataRow
{
    public OctoObjectId? RtId { get; init; }
    public RtCkId<CkTypeId>? CkTypeId { get; init; }
    public DateTime? Timestamp { get; init; }
    public string? RtWellKnownName { get; init; }
    public IReadOnlyDictionary<string, object?> Values { get; init; }
        = new Dictionary<string, object?>();
}
```

`StreamDataQueryResult.cs`:

```csharp
namespace Meshmakers.Octo.Runtime.Contracts.StreamData;

public class StreamDataQueryResult
{
    public required IReadOnlyList<StreamDataRow> Rows { get; init; }
    public required long TotalCount { get; init; }
}
```

- [ ] **Step 4: Create IStreamDataRepository interface**

```csharp
namespace Meshmakers.Octo.Runtime.Contracts.StreamData;

public interface IStreamDataRepository
{
    Task EnsureDatabaseCreatedAsync();
    Task DeleteDatabaseAsync();

    Task InsertAsync(StreamDataPoint datapoint);
    Task InsertAsync(IEnumerable<StreamDataPoint> datapoints);

    Task<StreamDataQueryResult> ExecuteQueryAsync(StreamDataQueryOptions options);
    Task<StreamDataQueryResult> ExecuteAggregationQueryAsync(StreamDataAggregationQueryOptions options);
    Task<StreamDataQueryResult> ExecuteGroupedAggregationQueryAsync(StreamDataGroupedAggregationQueryOptions options);
    Task<StreamDataQueryResult> ExecuteDownsamplingQueryAsync(StreamDataDownsamplingQueryOptions options);
}
```

- [ ] **Step 5: Verify engine compiles**

Run: `dotnet build -c DebugL octo-construction-kit-engine/`

Expected: Build succeeds. (Query options classes are created in Task 8.)

- [ ] **Step 6: Commit**

```
AB#3364: Add IStreamDataRepository, engine-level types, and canonical enums
```

---

### Task 8: Add fluent query options builders

**Files:**
- Create: `octo-construction-kit-engine/src/Runtime.Contracts/StreamData/StreamDataQueryOptions.cs`
- Create: `octo-construction-kit-engine/src/Runtime.Contracts/StreamData/StreamDataAggregationQueryOptions.cs`
- Create: `octo-construction-kit-engine/src/Runtime.Contracts/StreamData/StreamDataGroupedAggregationQueryOptions.cs`
- Create: `octo-construction-kit-engine/src/Runtime.Contracts/StreamData/StreamDataDownsamplingQueryOptions.cs`

- [ ] **Step 1: Create base options and simple query options**

`StreamDataQueryOptions.cs`:

```csharp
using Meshmakers.Octo.ConstructionKit.Contracts;

namespace Meshmakers.Octo.Runtime.Contracts.StreamData;

public abstract class StreamDataQueryOptionsBase
{
    public RtCkId<CkTypeId> CkTypeId { get; protected set; }
    public IReadOnlyList<string> Columns { get; protected set; } = [];
    public IReadOnlyList<OctoObjectId>? RtIds { get; protected set; }
    public DateTime? From { get; protected set; }
    public DateTime? To { get; protected set; }
    public int? Limit { get; protected set; }
    public IReadOnlyList<StreamDataSortOrder>? SortOrders { get; protected set; }
    public IReadOnlyList<StreamDataFieldFilter>? FieldFilters { get; protected set; }
    public int? Offset { get; protected set; }
    public int? PageSize { get; protected set; }
}

public class StreamDataQueryOptions : StreamDataQueryOptionsBase
{
    public static StreamDataQueryOptions Create() => new();

    public StreamDataQueryOptions WithCkTypeId(RtCkId<CkTypeId> id)
    {
        CkTypeId = id;
        return this;
    }

    public StreamDataQueryOptions WithColumns(IReadOnlyList<string> columns)
    {
        Columns = columns;
        return this;
    }

    public StreamDataQueryOptions WithRtIds(IReadOnlyList<OctoObjectId>? ids)
    {
        RtIds = ids;
        return this;
    }

    public StreamDataQueryOptions WithTimeRange(DateTime? from, DateTime? to)
    {
        From = from;
        To = to;
        return this;
    }

    public StreamDataQueryOptions WithLimit(int? limit)
    {
        Limit = limit;
        return this;
    }

    public StreamDataQueryOptions WithSortOrders(IReadOnlyList<StreamDataSortOrder>? sortOrders)
    {
        SortOrders = sortOrders;
        return this;
    }

    public StreamDataQueryOptions WithFieldFilters(IReadOnlyList<StreamDataFieldFilter>? fieldFilters)
    {
        FieldFilters = fieldFilters;
        return this;
    }

    public StreamDataQueryOptions WithPagination(int? offset, int? pageSize)
    {
        Offset = offset;
        PageSize = pageSize;
        return this;
    }
}
```

- [ ] **Step 2: Create aggregation query options**

`StreamDataAggregationQueryOptions.cs`:

```csharp
using Meshmakers.Octo.ConstructionKit.Contracts;

namespace Meshmakers.Octo.Runtime.Contracts.StreamData;

public class StreamDataAggregationQueryOptions : StreamDataQueryOptionsBase
{
    public IReadOnlyList<StreamDataAggregationColumn> AggregationColumns { get; private set; } = [];

    public static StreamDataAggregationQueryOptions Create() => new();

    public StreamDataAggregationQueryOptions WithCkTypeId(RtCkId<CkTypeId> id)
    {
        CkTypeId = id;
        return this;
    }

    public StreamDataAggregationQueryOptions WithAggregationColumns(
        IReadOnlyList<StreamDataAggregationColumn> columns)
    {
        AggregationColumns = columns;
        return this;
    }

    public StreamDataAggregationQueryOptions WithTimeRange(DateTime? from, DateTime? to)
    {
        From = from;
        To = to;
        return this;
    }

    public StreamDataAggregationQueryOptions WithLimit(int? limit)
    {
        Limit = limit;
        return this;
    }

    public StreamDataAggregationQueryOptions WithFieldFilters(
        IReadOnlyList<StreamDataFieldFilter>? fieldFilters)
    {
        FieldFilters = fieldFilters;
        return this;
    }

    public StreamDataAggregationQueryOptions WithRtIds(IReadOnlyList<OctoObjectId>? ids)
    {
        RtIds = ids;
        return this;
    }

    public StreamDataAggregationQueryOptions WithPagination(int? offset, int? pageSize)
    {
        Offset = offset;
        PageSize = pageSize;
        return this;
    }
}
```

- [ ] **Step 3: Create grouped aggregation query options**

`StreamDataGroupedAggregationQueryOptions.cs`:

```csharp
using Meshmakers.Octo.ConstructionKit.Contracts;

namespace Meshmakers.Octo.Runtime.Contracts.StreamData;

public class StreamDataGroupedAggregationQueryOptions : StreamDataQueryOptionsBase
{
    public IReadOnlyList<StreamDataAggregationColumn> AggregationColumns { get; private set; } = [];
    public IReadOnlyList<string> GroupByColumns { get; private set; } = [];

    public static StreamDataGroupedAggregationQueryOptions Create() => new();

    public StreamDataGroupedAggregationQueryOptions WithCkTypeId(RtCkId<CkTypeId> id)
    {
        CkTypeId = id;
        return this;
    }

    public StreamDataGroupedAggregationQueryOptions WithAggregationColumns(
        IReadOnlyList<StreamDataAggregationColumn> columns)
    {
        AggregationColumns = columns;
        return this;
    }

    public StreamDataGroupedAggregationQueryOptions WithGroupByColumns(
        IReadOnlyList<string> columns)
    {
        GroupByColumns = columns;
        return this;
    }

    public StreamDataGroupedAggregationQueryOptions WithTimeRange(DateTime? from, DateTime? to)
    {
        From = from;
        To = to;
        return this;
    }

    public StreamDataGroupedAggregationQueryOptions WithLimit(int? limit)
    {
        Limit = limit;
        return this;
    }

    public StreamDataGroupedAggregationQueryOptions WithFieldFilters(
        IReadOnlyList<StreamDataFieldFilter>? fieldFilters)
    {
        FieldFilters = fieldFilters;
        return this;
    }

    public StreamDataGroupedAggregationQueryOptions WithRtIds(IReadOnlyList<OctoObjectId>? ids)
    {
        RtIds = ids;
        return this;
    }

    public StreamDataGroupedAggregationQueryOptions WithPagination(int? offset, int? pageSize)
    {
        Offset = offset;
        PageSize = pageSize;
        return this;
    }
}
```

- [ ] **Step 4: Create downsampling query options**

`StreamDataDownsamplingQueryOptions.cs`:

```csharp
using Meshmakers.Octo.ConstructionKit.Contracts;

namespace Meshmakers.Octo.Runtime.Contracts.StreamData;

public class StreamDataDownsamplingQueryOptions : StreamDataQueryOptionsBase
{
    public IReadOnlyList<StreamDataAggregationColumn> AggregationColumns { get; private set; } = [];
    public TimeSpan BinInterval { get; private set; }

    public static StreamDataDownsamplingQueryOptions Create() => new();

    public StreamDataDownsamplingQueryOptions WithCkTypeId(RtCkId<CkTypeId> id)
    {
        CkTypeId = id;
        return this;
    }

    public StreamDataDownsamplingQueryOptions WithAggregationColumns(
        IReadOnlyList<StreamDataAggregationColumn> columns)
    {
        AggregationColumns = columns;
        return this;
    }

    public StreamDataDownsamplingQueryOptions WithBinInterval(TimeSpan interval)
    {
        BinInterval = interval;
        return this;
    }

    public StreamDataDownsamplingQueryOptions WithTimeRange(DateTime? from, DateTime? to)
    {
        From = from;
        To = to;
        return this;
    }

    public StreamDataDownsamplingQueryOptions WithLimit(int? limit)
    {
        Limit = limit;
        return this;
    }

    public StreamDataDownsamplingQueryOptions WithFieldFilters(
        IReadOnlyList<StreamDataFieldFilter>? fieldFilters)
    {
        FieldFilters = fieldFilters;
        return this;
    }

    public StreamDataDownsamplingQueryOptions WithRtIds(IReadOnlyList<OctoObjectId>? ids)
    {
        RtIds = ids;
        return this;
    }

    public StreamDataDownsamplingQueryOptions WithPagination(int? offset, int? pageSize)
    {
        Offset = offset;
        PageSize = pageSize;
        return this;
    }
}
```

- [ ] **Step 5: Verify engine compiles**

Run: `dotnet build -c DebugL octo-construction-kit-engine/`

Expected: Build succeeds.

- [ ] **Step 6: Commit**

```
AB#3364: Add fluent query options builders for all stream data query types
```

---

### Task 9: Add GetStreamDataRepository() to ITenantContext

**Files:**
- Modify: `octo-construction-kit-engine-mongodb/src/Runtime.Contracts.MongoDb/ITenantContext.cs`
- Modify: `octo-construction-kit-engine-mongodb/src/Runtime.Engine.MongoDb/TenantContext.cs`
- Modify: `octo-construction-kit-engine-mongodb/src/Runtime.Contracts.MongoDb/Runtime.Contracts.MongoDb.csproj`

- [ ] **Step 1: Add to ITenantContext interface**

Add to `ITenantContext.cs`:

```csharp
using Meshmakers.Octo.Runtime.Contracts.StreamData;

// In the interface body:

/// <summary>
/// Returns the stream data repository for this tenant, or null if stream data is not enabled.
/// </summary>
IStreamDataRepository? GetStreamDataRepository();
```

Note: `Runtime.Contracts.MongoDb.csproj` already references `Meshmakers.Octo.Runtime.Contracts`, so the `IStreamDataRepository` type from `Runtime.Contracts.StreamData` is already available.

- [ ] **Step 2: Add stub implementation to TenantContext**

In `TenantContext.cs`, add the minimal implementation that returns null for now (will be wired in Phase 3):

```csharp
public IStreamDataRepository? GetStreamDataRepository()
{
    return null; // Will be implemented in Phase 3
}
```

- [ ] **Step 3: Fix any compilation errors in dependent projects**

If any other classes implement `ITenantContext` (e.g., test fakes, `SystemContext`), add the `GetStreamDataRepository()` stub to them as well.

- [ ] **Step 4: Verify full build chain**

Build `octo-construction-kit-engine-mongodb` and `octo-common-services` (which depends on it).

Expected: Both compile.

- [ ] **Step 5: Commit**

```
AB#3364: Add GetStreamDataRepository() to ITenantContext
```

---

## Phase 3: Engine Implementation

### Task 10: Implement CrateDbStreamDataRepository — simple queries

**Files:**
- Create: `octo-construction-kit-engine-mongodb/src/Runtime.Engine.MongoDb/StreamData/CrateDbStreamDataRepository.cs`

This is the core of the migration. Extract the query orchestration logic from `StreamDataQuery.cs` (GraphQL resolver in asset-repo) into the repository.

- [ ] **Step 1: Write a failing test for ExecuteQueryAsync**

Create `octo-construction-kit-engine-mongodb/tests/StreamData.Tests/CrateDbStreamDataRepositoryTests.cs` — an integration test using Testcontainers CrateDB.

Test: insert known data points → call `ExecuteQueryAsync` with columns → verify rows returned match.

- [ ] **Step 2: Create CrateDbStreamDataRepository skeleton**

```csharp
using Meshmakers.Octo.Runtime.Contracts.StreamData;

namespace Meshmakers.Octo.Runtime.Engine.MongoDb.StreamData;

public class CrateDbStreamDataRepository : IStreamDataRepository
{
    private readonly IStreamDataDatabaseClient _databaseClient;
    private readonly IStreamDataDatabaseManagementClient _managementClient;
    private readonly string _tenantId;

    public CrateDbStreamDataRepository(
        IStreamDataDatabaseClient databaseClient,
        IStreamDataDatabaseManagementClient managementClient,
        string tenantId)
    {
        _databaseClient = databaseClient;
        _managementClient = managementClient;
        _tenantId = tenantId;
    }

    // Implement all interface methods...
}
```

- [ ] **Step 3: Implement ExecuteQueryAsync**

Move the logic from `StreamDataQuery.ResolveStreamDataRtQueryAsync` and `ResolveTransientStreamDataQueryAsync` into this method:
- Build `CrateQueryBuilder` from `StreamDataQueryOptions`
- Map `StreamDataFieldFilterOperator` → CrateDB filter operators
- Map `StreamDataSortDirection` → CrateDB sort orders
- Handle pagination (offset/rowCap/tiebreaker)
- Compile and execute via `IStreamDataDatabaseClient`
- Map `DataPointDto` results → `StreamDataRow`
- Return `StreamDataQueryResult` with rows and total count

- [ ] **Step 4: Implement InsertAsync methods**

Map `StreamDataPoint` → `DataPointDto` → delegate to `IStreamDataDatabaseClient`.

- [ ] **Step 5: Implement lifecycle methods**

`EnsureDatabaseCreatedAsync` and `DeleteDatabaseAsync` delegate to `IStreamDataDatabaseManagementClient`.

- [ ] **Step 6: Run tests to verify simple queries work**

Expected: Integration test PASSES.

- [ ] **Step 7: Commit**

```
AB#3364: Implement CrateDbStreamDataRepository for simple queries
```

---

### Task 11: Implement CrateDbStreamDataRepository — aggregation and downsampling queries

**Files:**
- Modify: `octo-construction-kit-engine-mongodb/src/Runtime.Engine.MongoDb/StreamData/CrateDbStreamDataRepository.cs`
- Modify: `octo-construction-kit-engine-mongodb/tests/StreamData.Tests/CrateDbStreamDataRepositoryTests.cs`

- [ ] **Step 1: Write failing tests for aggregation queries**

Test: insert data → call `ExecuteAggregationQueryAsync` with AVG function → verify aggregated result.
Test: insert data → call `ExecuteGroupedAggregationQueryAsync` with GROUP BY → verify grouped results.

- [ ] **Step 2: Implement ExecuteAggregationQueryAsync**

Move logic from `StreamDataQuery.ResolveStreamDataAggregationRtQueryAsync` — map `StreamDataAggregationFunction` → `AggregationFunctionDto`, build query with aggregation variables.

- [ ] **Step 3: Implement ExecuteGroupedAggregationQueryAsync**

Move logic from `StreamDataQuery.ResolveStreamDataGroupingAggregationRtQueryAsync` — add GROUP BY columns.

- [ ] **Step 4: Write failing test for downsampling**

Test: insert time-series data → call `ExecuteDownsamplingQueryAsync` with bin interval → verify time bins.

- [ ] **Step 5: Implement ExecuteDownsamplingQueryAsync**

Move logic from `StreamDataQuery.ResolveStreamDataDownsamplingRtQueryAsync` — handle `DATE_BIN`, `generate_series` LEFT JOIN, empty bin detection.

- [ ] **Step 6: Run all repository tests**

Expected: All PASS.

- [ ] **Step 7: Commit**

```
AB#3364: Implement aggregation and downsampling queries in CrateDbStreamDataRepository
```

---

### Task 12: Wire CrateDbStreamDataRepository into TenantContext and DI

**Files:**
- Create: `octo-construction-kit-engine-mongodb/src/Runtime.Engine.MongoDb/Configuration/DependencyInjection/StreamDataEngineBuilderExtensions.cs`
- Modify: `octo-construction-kit-engine-mongodb/src/Runtime.Engine.MongoDb/TenantContext.cs`

- [ ] **Step 1: Create AddCrateDbStreamDataRepository extension**

```csharp
using Meshmakers.Octo.Runtime.Engine.Configuration.DependencyInjection;
using Meshmakers.Octo.Runtime.Engine.MongoDb.StreamData;
using Meshmakers.Octo.Runtime.Engine.MongoDb.StreamData.Client;

// ReSharper disable once CheckNamespace
namespace Microsoft.Extensions.DependencyInjection;

public static class StreamDataEngineBuilderExtensions
{
    public static IRuntimeEngineBuilder AddCrateDbStreamDataRepository(
        this IRuntimeEngineBuilder builder)
    {
        builder.Services.AddSingleton<ICrateDbConnectionAccess, CrateDbClientAccess>();
        builder.Services.AddSingleton<IStreamDataDatabaseClient, CrateDatabaseClient>();
        builder.Services.AddSingleton<IStreamDataDatabaseManagementClient, CrateDatabaseClient>();
        builder.Services.AddSingleton<IStreamDataHealthCheckClient, CrateDatabaseClient>();

        return builder;
    }
}
```

- [ ] **Step 2: Wire GetStreamDataRepository() in TenantContext**

Replace the stub from Task 9 with the real implementation in `TenantContext.cs`:

```csharp
private IStreamDataRepository? _streamDataRepository;
private bool _streamDataInitialized;

public IStreamDataRepository? GetStreamDataRepository()
{
    if (_streamDataInitialized)
        return _streamDataRepository;

    _streamDataInitialized = true;

    // Check if stream data is enabled for this tenant
    // (reads from tenant configuration in MongoDB)
    var databaseClient = _serviceProvider.GetService<IStreamDataDatabaseClient>();
    var managementClient = _serviceProvider.GetService<IStreamDataDatabaseManagementClient>();

    if (databaseClient == null || managementClient == null)
        return null;

    _streamDataRepository = new CrateDbStreamDataRepository(
        databaseClient,
        managementClient,
        TenantId);

    return _streamDataRepository;
}
```

The exact wiring depends on how `TenantContext` accesses services. Follow the existing pattern used by `GetTenantRepository()`.

- [ ] **Step 3: Verify engine-mongodb compiles**

Run: `dotnet build -c DebugL octo-construction-kit-engine-mongodb/`

Expected: Build succeeds.

- [ ] **Step 4: Commit**

```
AB#3364: Wire CrateDbStreamDataRepository into TenantContext and DI
```

---

### Task 13: Move tenant lifecycle management into engine

**Files:**
- Modify: `octo-construction-kit-engine-mongodb/src/Runtime.Engine.MongoDb/TenantContext.cs`
- Modify: `octo-construction-kit-engine-mongodb/src/Runtime.Contracts.MongoDb/ITenantContext.cs`

Move the enable/disable stream data logic from `octo-asset-repo-services/StreamData/Services/TenantManager.cs` into the engine.

- [ ] **Step 1: Add enable/disable methods to ITenantContext**

```csharp
/// <summary>
/// Enables stream data for this tenant, creating the CrateDB table if needed.
/// </summary>
Task EnableStreamDataAsync();

/// <summary>
/// Disables stream data for this tenant, deleting the CrateDB table.
/// </summary>
Task DisableStreamDataAsync();
```

- [ ] **Step 2: Implement in TenantContext**

Move the logic from `TenantManager.EnableStreamData` and `TenantManager.DisableStreamDataAsync`:
- Set/unset `StreamDataEnabledKey` in tenant configuration
- Call `EnsureDatabaseCreatedAsync()` / `DeleteDatabaseAsync()` on the repository
- Reset cached `_streamDataRepository`

- [ ] **Step 3: Fix compilation in dependent projects**

Add stubs to any other `ITenantContext` implementations.

- [ ] **Step 4: Verify build**

Expected: engine-mongodb and common-services compile.

- [ ] **Step 5: Commit**

```
AB#3364: Move stream data tenant lifecycle management into engine
```

---

## Phase 4: Thin Out GraphQL

### Task 14: Create StreamDataGraphQlMapper

**Files:**
- Create: `octo-asset-repo-services/src/AssetRepositoryServices/GraphQL/StreamDataGraphQlMapper.cs`

- [ ] **Step 1: Create consolidated mapper class**

```csharp
using Meshmakers.Octo.Runtime.Contracts.StreamData;

namespace Meshmakers.Octo.Backend.AssetRepositoryServices.GraphQL;

internal static class StreamDataGraphQlMapper
{
    public static StreamDataFieldFilterOperator MapOperator(FieldFilterOperatorDto op)
    {
        return op switch
        {
            FieldFilterOperatorDto.Equals => StreamDataFieldFilterOperator.Equals,
            FieldFilterOperatorDto.NotEquals => StreamDataFieldFilterOperator.NotEquals,
            FieldFilterOperatorDto.GreaterThan => StreamDataFieldFilterOperator.GreaterThan,
            FieldFilterOperatorDto.GreaterThanOrEqual => StreamDataFieldFilterOperator.GreaterThanOrEqual,
            FieldFilterOperatorDto.LessThan => StreamDataFieldFilterOperator.LessThan,
            FieldFilterOperatorDto.LessThanOrEqual => StreamDataFieldFilterOperator.LessThanOrEqual,
            FieldFilterOperatorDto.Like => StreamDataFieldFilterOperator.Like,
            _ => throw new ArgumentOutOfRangeException(nameof(op), op, null)
        };
    }

    public static StreamDataSortDirection MapSortDirection(SortOrderDto sort)
    {
        return sort switch
        {
            SortOrderDto.Ascending => StreamDataSortDirection.Ascending,
            SortOrderDto.Descending => StreamDataSortDirection.Descending,
            _ => throw new ArgumentOutOfRangeException(nameof(sort), sort, null)
        };
    }

    public static StreamDataAggregationFunction MapAggregation(/* CK aggregation type */)
    {
        // Map from the CK model aggregation enum to the engine enum
        // Exact source enum depends on current code
    }

    public static IReadOnlyList<StreamDataFieldFilter>? MapFilters(
        IReadOnlyList<FieldFilterDto>? filters)
    {
        // Map GraphQL filter DTOs to engine filter types
    }

    public static IReadOnlyList<StreamDataSortOrder>? MapSorts(
        IReadOnlyList<SortOrderItemDto>? sorts)
    {
        // Map GraphQL sort DTOs to engine sort types
    }
}
```

Adapt the exact DTO type names from the current codebase. The point is: one mapping file, one direction (GraphQL → engine).

- [ ] **Step 2: Commit**

```
AB#3364: Add StreamDataGraphQlMapper for consolidated type conversion
```

---

### Task 15: Rewrite StreamDataQuery.cs resolvers to be thin

**Files:**
- Modify: `octo-asset-repo-services/src/AssetRepositoryServices/GraphQL/StreamDataQuery.cs`

This is the big payoff. Rewrite all 8 resolver methods to use `IStreamDataRepository` from `ITenantContext`.

- [ ] **Step 1: Rewrite ResolveStreamDataRtQueryAsync (persisted simple)**

Replace the ~170 lines with ~30 lines:
1. Load persisted query entity from tenant repository
2. Build `StreamDataQueryOptions` from entity + runtime arguments
3. Call `streamDataRepo.ExecuteQueryAsync(options)`
4. Map result to GraphQL connection

- [ ] **Step 2: Rewrite ResolveTransientStreamDataQueryAsync (transient simple)**

Same pattern but build options from GraphQL arguments.

- [ ] **Step 3: Rewrite ResolveStreamDataAggregationRtQueryAsync (persisted aggregation)**

- [ ] **Step 4: Rewrite ResolveTransientStreamDataAggregationQueryAsync (transient aggregation)**

- [ ] **Step 5: Rewrite ResolveStreamDataGroupingAggregationRtQueryAsync (persisted grouped)**

- [ ] **Step 6: Rewrite ResolveTransientStreamDataGroupedAggregationQueryAsync (transient grouped)**

- [ ] **Step 7: Rewrite ResolveStreamDataDownsamplingRtQueryAsync (persisted downsampling)**

- [ ] **Step 8: Rewrite ResolveTransientStreamDataDownsamplingQueryAsync (transient downsampling)**

- [ ] **Step 9: Remove all CrateQueryBuilder/Compiler/FieldResolver imports and usage**

Remove `using Meshmakers.Octo.Runtime.Engine.MongoDb.StreamData.QueryBuilder` and similar. The GraphQL layer should only reference engine contracts.

- [ ] **Step 10: Remove old helper methods**

Delete `ExecutePaginatedStreamDataQueryAsync`, `MapFieldFilterOperatorDto`, `MapFieldFilterOperator`, `MapCkAggregationType`, `HandleRequestedAttributes`, and any other helper methods that were inlined into the repository.

- [ ] **Step 11: Update Program.cs DI registration**

In `octo-asset-repo-services/src/AssetRepositoryServices/Program.cs`, replace:

```csharp
builder.Services.AddStreamDataManagement()
    .AddStreamDataDatabase<ConfigureStreamDataConfiguration>();
```

With:

```csharp
builder.Services.AddRuntimeEngine()
    .AddMongoDbRuntimeRepository()
    .AddCrateDbStreamDataRepository();  // new
```

(If `AddRuntimeEngine().AddMongoDbRuntimeRepository()` is already called, just add `.AddCrateDbStreamDataRepository()` to the chain.)

- [ ] **Step 12: Verify asset-repo compiles**

Run: `dotnet build -c DebugL octo-asset-repo-services/`

Expected: Build succeeds.

- [ ] **Step 13: Run Phase 1 integration tests**

Run: `dotnet test -c DebugL --filter "FullyQualifiedName~StreamData" octo-asset-repo-services/tests/AssetRepositoryServices.IntegrationTests/`

Expected: ALL Phase 1 tests PASS. This is the critical verification that the migration preserved behavior.

- [ ] **Step 14: Commit**

```
AB#3364: Rewrite GraphQL stream data resolvers to use engine repository
```

---

### Task 16: Update mesh-adapter to use engine repository

**Files:**
- Modify: `octo-mesh-adapter/src/MeshAdapter.Sdk/Nodes/Load/SaveInTimeSeries.cs`
- Modify: `octo-mesh-adapter/src/MeshAdapter.Sdk/Configuration/DependencyInjection/ServiceCollectionExtensions.cs`

- [ ] **Step 1: Update SaveInTimeSeries to use IStreamDataRepository**

Replace direct `IStreamDataDatabaseClient` usage with `ITenantContext.GetStreamDataRepository()`.

- [ ] **Step 2: Update DI registration**

Replace `AddStreamDataDatabase` call with `AddCrateDbStreamDataRepository()`.

- [ ] **Step 3: Verify mesh-adapter compiles and tests pass**

Run: `dotnet build -c DebugL octo-mesh-adapter/`
Run: `dotnet test -c DebugL octo-mesh-adapter/`

Expected: Both pass.

- [ ] **Step 4: Commit**

```
AB#3364: Update mesh-adapter to use engine stream data repository
```

---

## Phase 5: Cleanup

### Task 17: Remove dead code

**Files:**
- Delete: `octo-asset-repo-services/src/AssetRepositoryServices/StreamData/Services/TenantManager.cs`
- Delete: `octo-asset-repo-services/src/AssetRepositoryServices/StreamData/Services/StreamDataTenantContext.cs`
- Delete: `octo-asset-repo-services/src/AssetRepositoryServices/StreamData/Services/TimeSeriesTenantContextFactory.cs`
- Delete: `octo-asset-repo-services/src/AssetRepositoryServices/StreamData/ServiceCollectionExtensions.cs`
- Delete: `octo-asset-repo-services/src/AssetRepositoryServices/StreamData/Constants.cs` (if moved)
- Delete: `octo-asset-repo-services/src/AssetRepositoryServices/StreamData/Configuration/` (if moved)
- Delete: `octo-common-services/src/StreamData/` (entire directory — already moved)
- Delete: `octo-common-services/tests/StreamData.Tests/` (entire directory — already moved)
- Modify: `octo-common-services/octo-common-services.sln` — remove StreamData and StreamData.Tests project references

- [ ] **Step 1: Delete dead files from asset-repo**

Remove `ITenantManager`, `IStreamDataTenantContext`, `IStreamDataTenantContextFactory`, `StreamDataTenantContextFactory`, `StreamDataDatabaseManager`, and their `ServiceCollectionExtensions`.

- [ ] **Step 2: Delete old StreamData from common-services**

Remove the entire `src/StreamData/` and `tests/StreamData.Tests/` directories. Update the solution file to remove project references.

- [ ] **Step 3: Verify full build chain**

Build all affected repos in order:
1. `octo-construction-kit-engine`
2. `octo-construction-kit-engine-mongodb`
3. `octo-common-services`
4. `octo-asset-repo-services`
5. `octo-mesh-adapter`

Expected: All compile.

- [ ] **Step 4: Run all tests**

Run tests in each repo to verify nothing broke.

Expected: All pass.

- [ ] **Step 5: Commit**

```
AB#3364: Remove dead stream data code from asset-repo and common-services
```

---

## Summary

| Phase | Tasks | Repos affected |
|---|---|---|
| 1: Test Harness | Tasks 1-3 | asset-repo |
| 2: Move + Contracts | Tasks 4-9 | common-services, engine, engine-mongodb |
| 3: Implementation | Tasks 10-13 | engine-mongodb |
| 4: Thin GraphQL | Tasks 14-16 | asset-repo, mesh-adapter |
| 5: Cleanup | Task 17 | asset-repo, common-services |
