# Stream ↔ Runtime Query Symmetry — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make stream-data queries structurally symmetric to runtime-data (RT) queries at every layer — CK model, engine contracts, GraphQL surface, and typed per-CkType entities — by reusing RT's types wherever the concept matches, introducing `Sd*` types that mirror `Rt*`, and collapsing stream's parallel GraphQL roots into RT's descriptor pattern.

**Architecture:** Shared engine contracts (`SortOrderItem`, `FieldFilter`, `AggregationTypes`, new `AggregationColumn`). Abstract `StreamDataQuery` CK base with `*SdQuery` subtypes mirroring `*RtQuery`. `SdEntity` base + source-generated `Sd{CkType}` classes. One persistent-query root (`StreamDataQuery(rtId)`) returning a descriptor with `.Rows`/`.Aggregations` sub-connections. Transient namespace `TransientStreamDataQuery.{Simple,Aggregation,GroupingAggregation,Downsampling}`. Generic endpoint `StreamDataEntities(ckId)`. `CrateQueryBuilder` becomes engine-internal.

**Tech Stack:** .NET 10, xUnit v3, CK model YAML, GraphQL.NET, Angular 21 + Apollo, Testcontainers (CrateDB + MongoDB).

**Spec:** `docs/superpowers/specs/2026-04-12-stream-rt-query-symmetry-design.md` — read it first.

**Branching:** every repo uses a new branch `feature/reimar/stream-rt-query-symmetry` created from the current branch (see Phase 0 + spec "BRANCHING — READ FIRST" section).

**Execution order:** Phases 0 → 7 strictly sequential. Each phase compiles and tests green before moving on.

---

## Phase 0 — Branching setup

Before any code change, create the new feature branch in every affected repo. The existing `feature/reimar/stream-data-engine-migration` branches stay as fallback.

### Task 0.1: Create feature branches across all repos

**Repos:**
- `octo-construction-kit-engine` — on `feature/reimar/stream-data-engine-migration`
- `octo-construction-kit-engine-mongodb` — on `feature/reimar/stream-data-engine-migration`
- `octo-common-services` — on `feature/reimar/stream-data-engine-migration`
- `octo-asset-repo-services` — on `feature/reimar/stream-data-engine-migration`
- `octo-mesh-adapter` — on `feature/reimar/stream-data-engine-migration`
- `octo-sdk` — on `main`
- `octo-frontend-refinery-studio` — on `main`
- `octo-tools` — on `main` (for plan/spec docs)

- [ ] **Step 1: Verify current branch in every repo matches the expected state**

```bash
for repo in octo-construction-kit-engine octo-construction-kit-engine-mongodb octo-common-services octo-asset-repo-services octo-mesh-adapter octo-sdk octo-frontend-refinery-studio octo-tools; do
  echo "=== $repo ==="
  git -C /Users/reimar/dev/meshmakers/branches/main/$repo status --short
  git -C /Users/reimar/dev/meshmakers/branches/main/$repo branch --show-current
done
```

Expected: all repos clean; first 5 on `feature/reimar/stream-data-engine-migration`; last 3 on `main`. Abort if any repo has uncommitted changes.

- [ ] **Step 2: Create new branch in each repo**

```bash
for repo in octo-construction-kit-engine octo-construction-kit-engine-mongodb octo-common-services octo-asset-repo-services octo-mesh-adapter octo-sdk octo-frontend-refinery-studio octo-tools; do
  echo "=== $repo ==="
  git -C /Users/reimar/dev/meshmakers/branches/main/$repo checkout -b feature/reimar/stream-rt-query-symmetry
done
```

Expected: each repo reports "Switched to a new branch 'feature/reimar/stream-rt-query-symmetry'".

- [ ] **Step 3: Confirm**

```bash
for repo in octo-construction-kit-engine octo-construction-kit-engine-mongodb octo-common-services octo-asset-repo-services octo-mesh-adapter octo-sdk octo-frontend-refinery-studio octo-tools; do
  git -C /Users/reimar/dev/meshmakers/branches/main/$repo branch --show-current
done
```

Expected: all print `feature/reimar/stream-rt-query-symmetry`.

No commit needed in this task — branches are created; no diffs yet.

---

## Phase 1 — Shared engine contracts

Replaces stream-specific enums and records with RT's existing types. Introduces a new shared `AggregationColumn` record. Adds CrateDB `Between` support. Extends `StreamDataRow` and `StreamDataPoint` with typed `RtCreationDateTime` / `RtChangedDateTime` fields.

### Task 1.0: Add `RtCreationDateTime` / `RtChangedDateTime` to `StreamDataRow` and `StreamDataPoint`

The CrateDB table physically stores these two datetimes (selected by `CrateQueryBuilder.IncludeDefaultVariables`), but today they land in `StreamDataRow.Values` as dict entries instead of typed members. Add them as typed fields so `SdEntity` hydration (Phase 3) can copy them directly.

**Files:**
- Modify: `octo-construction-kit-engine/src/Runtime.Contracts/StreamData/StreamDataRow.cs`
- Modify: `octo-construction-kit-engine/src/Runtime.Contracts/StreamData/StreamDataPoint.cs`
- Modify: `octo-construction-kit-engine-mongodb/src/Runtime.Engine.MongoDb/StreamData/CrateDbStreamDataRepository.cs`
- Modify: `octo-asset-repo-services/src/AssetRepositoryServices/GraphQL/Types/StreamDataQueryRowDtoType.cs` (both the DTO record and the GraphQL type)

- [ ] **Step 1: Add the typed fields to `StreamDataRow`**

```csharp
public class StreamDataRow
{
    public OctoObjectId? RtId { get; init; }
    public RtCkId<CkTypeId>? CkTypeId { get; init; }
    public DateTime? Timestamp { get; init; }
    public string? RtWellKnownName { get; init; }
    public DateTime? RtCreationDateTime { get; init; }
    public DateTime? RtChangedDateTime { get; init; }
    public IReadOnlyDictionary<string, object?> Values { get; init; }
        = new Dictionary<string, object?>();
}
```

- [ ] **Step 2: Add the same two fields to `StreamDataPoint`**

Insert-side producers (mesh-adapter) can now write these explicitly. Match the existing nullable pattern.

- [ ] **Step 3: Update `CrateDbStreamDataRepository` row materialization**

Find the code that converts CrateDB result rows into `StreamDataRow` instances (likely in `ExecuteQueryAsync` or a helper that maps `IDataReader` / Dapper rows). Pull `RtCreationDateTime` and `RtChangedDateTime` off the row into the new typed fields rather than leaving them in `Values`.

Also update insert-side (`InsertAsync`) to write the new `StreamDataPoint` fields to their respective columns.

- [ ] **Step 3.5: Extend `StreamDataQueryRowDto` in asset-repo**

In `octo-asset-repo-services/src/AssetRepositoryServices/GraphQL/Types/StreamDataQueryRowDtoType.cs`, add the two fields to both the DTO record and the GraphQL `StreamDataQueryRowDtoType` constructor:

```csharp
// In StreamDataQueryRowDto record:
public DateTime? RtCreationDateTime { get; set; }
public DateTime? RtChangedDateTime { get; set; }

// In FromStreamDataRow:
RtCreationDateTime = row.RtCreationDateTime,
RtChangedDateTime = row.RtChangedDateTime,

// In StreamDataQueryRowDtoType constructor, after existing Field calls:
Field(d => d.RtCreationDateTime, typeof(DateTimeGraphType));
Field(d => d.RtChangedDateTime, typeof(DateTimeGraphType));
```

- [ ] **Step 4: Build + tests**

```bash
dotnet build /Users/reimar/dev/meshmakers/branches/main/octo-construction-kit-engine -c DebugL 2>&1 | tail -3
dotnet build /Users/reimar/dev/meshmakers/branches/main/octo-construction-kit-engine-mongodb -c DebugL 2>&1 | tail -3
dotnet build /Users/reimar/dev/meshmakers/branches/main/octo-asset-repo-services -c DebugL 2>&1 | tail -3
dotnet test /Users/reimar/dev/meshmakers/branches/main/octo-construction-kit-engine-mongodb/tests/StreamData.UnitTests -c DebugL --no-build 2>&1 | tail -3
```

Expected: green. Existing tests that populated `Values["RtCreationDateTime"]` still work (the field can still be set manually for tests), but tests that read from the row should prefer the typed field.

- [ ] **Step 5: Commit**

```bash
git -C /Users/reimar/dev/meshmakers/branches/main/octo-construction-kit-engine add src/Runtime.Contracts/StreamData/
git -C /Users/reimar/dev/meshmakers/branches/main/octo-construction-kit-engine commit -m "Surface RtCreationDateTime/RtChangedDateTime as typed fields on StreamDataRow/Point

Physical CrateDB schema already stores these; they previously landed in
StreamDataRow.Values. Promoting them to typed members so SdEntity
hydration can copy them directly and clients can use them without dict
lookups.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"

git -C /Users/reimar/dev/meshmakers/branches/main/octo-construction-kit-engine-mongodb add src/Runtime.Engine.MongoDb/StreamData/
git -C /Users/reimar/dev/meshmakers/branches/main/octo-construction-kit-engine-mongodb commit -m "Populate RtCreationDateTime/RtChangedDateTime typed fields from CrateDB rows

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"

git -C /Users/reimar/dev/meshmakers/branches/main/octo-asset-repo-services add src/AssetRepositoryServices/GraphQL/Types/StreamDataQueryRowDtoType.cs
git -C /Users/reimar/dev/meshmakers/branches/main/octo-asset-repo-services commit -m "Surface RtCreationDateTime/RtChangedDateTime on StreamDataQueryRowDto

GraphQL-side row DTO gains the two datetimes that just became typed
fields on StreamDataRow, so cells-based descriptor paths expose them.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

### Task 1.1: Add shared `AggregationColumn` record

**Files:**
- Create: `octo-construction-kit-engine/src/Runtime.Contracts/Repositories/Query/AggregationColumn.cs`

- [ ] **Step 1: Create the record**

```csharp
using Meshmakers.Common.Shared;

namespace Meshmakers.Octo.Runtime.Contracts.Repositories.Query;

/// <summary>
///     Specifies a single aggregation column: the attribute path to aggregate and the function to apply.
/// </summary>
public class AggregationColumn
{
    /// <summary>
    ///     Creates a new instance.
    /// </summary>
    public AggregationColumn(string attributePath, AggregationTypes function)
    {
        ArgumentValidation.ValidateString(nameof(attributePath), attributePath);

        AttributePath = attributePath;
        Function = function;
    }

    /// <summary>
    ///     Path to the attribute to aggregate.
    /// </summary>
    public string AttributePath { get; }

    /// <summary>
    ///     Aggregation function to apply.
    /// </summary>
    public AggregationTypes Function { get; }

    /// <inheritdoc />
    public override string ToString() => $"{Function}({AttributePath})";
}
```

Note: `AggregationTypes` is the CK-generated enum from the System CK model. Import path is `Meshmakers.Octo.ConstructionKit.Models.System.Generated.System.v2`. Add the using if the file doesn't compile without it.

- [ ] **Step 2: Build to verify**

```bash
dotnet build /Users/reimar/dev/meshmakers/branches/main/octo-construction-kit-engine -c DebugL
```

Expected: build succeeds.

- [ ] **Step 3: Commit**

```bash
git -C /Users/reimar/dev/meshmakers/branches/main/octo-construction-kit-engine add src/Runtime.Contracts/Repositories/Query/AggregationColumn.cs
git -C /Users/reimar/dev/meshmakers/branches/main/octo-construction-kit-engine commit -m "Add shared AggregationColumn record to runtime query contracts

Will be consumed by stream data options in the query-symmetry refactor.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

### Task 1.2: Swap stream options to shared RT types

**Files:**
- Modify: `octo-construction-kit-engine/src/Runtime.Contracts/StreamData/StreamDataQueryOptions.cs`
- Modify: `octo-construction-kit-engine/src/Runtime.Contracts/StreamData/StreamDataAggregationQueryOptions.cs`
- Modify: `octo-construction-kit-engine/src/Runtime.Contracts/StreamData/StreamDataGroupedAggregationQueryOptions.cs`
- Modify: `octo-construction-kit-engine/src/Runtime.Contracts/StreamData/StreamDataDownsamplingQueryOptions.cs`

- [ ] **Step 1: Update `StreamDataQueryOptions.cs` base to use RT types**

Change signatures:
```csharp
// Before
public IReadOnlyList<StreamDataSortOrder>? SortOrders { get; protected set; }
public IReadOnlyList<StreamDataFieldFilter>? FieldFilters { get; protected set; }

// After
public IReadOnlyList<SortOrderItem>? SortOrders { get; protected set; }
public IReadOnlyList<FieldFilter>? FieldFilters { get; protected set; }
```

Add using: `using Meshmakers.Octo.Runtime.Contracts.Repositories.Query;`

Change the `With*` methods correspondingly:
```csharp
public StreamDataQueryOptions WithSortOrders(IReadOnlyList<SortOrderItem>? orders) { SortOrders = orders; return this; }
public StreamDataQueryOptions WithFieldFilters(IReadOnlyList<FieldFilter>? filters) { FieldFilters = filters; return this; }
```

- [ ] **Step 2: Update the three variant option classes the same way**

`StreamDataAggregationQueryOptions`, `StreamDataGroupedAggregationQueryOptions`, `StreamDataDownsamplingQueryOptions` — swap their `SortOrders` and `FieldFilters` properties and `With*` setters to use `SortOrderItem` / `FieldFilter`. For the aggregation-column-carrying option classes, swap:

```csharp
// Before
public IReadOnlyList<StreamDataAggregationColumn> AggregationColumns { get; protected set; }
public XxxOptions WithAggregationColumns(IReadOnlyList<StreamDataAggregationColumn> cols) { ... }

// After
public IReadOnlyList<AggregationColumn> AggregationColumns { get; protected set; }
public XxxOptions WithAggregationColumns(IReadOnlyList<AggregationColumn> cols) { ... }
```

- [ ] **Step 3: Build engine — expect errors from downstream consumers**

```bash
dotnet build /Users/reimar/dev/meshmakers/branches/main/octo-construction-kit-engine -c DebugL 2>&1 | tail -20
```

Expected: engine compiles (no dependency on `StreamData*` types deleted-in-next-task yet). Downstream repos (`octo-construction-kit-engine-mongodb`, `octo-asset-repo-services`) will error — that's addressed in Task 1.3.

- [ ] **Step 4: Commit**

```bash
git -C /Users/reimar/dev/meshmakers/branches/main/octo-construction-kit-engine add src/Runtime.Contracts/StreamData/
git -C /Users/reimar/dev/meshmakers/branches/main/octo-construction-kit-engine commit -m "Swap stream options to shared RT engine types

StreamDataQueryOptions and three variants now use SortOrderItem,
FieldFilter, and the new AggregationColumn. Stream-specific records are
still defined in StreamData/ and will be deleted in a follow-up commit
once downstream consumers are updated.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

### Task 1.3: Update engine-mongodb repository implementation

**Files:**
- Modify: `octo-construction-kit-engine-mongodb/src/Runtime.Engine.MongoDb/StreamData/CrateDbStreamDataRepository.cs`

The repository's SQL-generation methods consume the options types from Task 1.2 and internally convert to `CrateQueryBuilder` calls.

- [ ] **Step 1: Inspect current usage of stream enums/records inside the repository**

```bash
grep -n "StreamDataSortOrder\|StreamDataFieldFilter\|StreamDataAggregationColumn\|StreamDataAggregationFunction\|StreamDataFieldFilterOperator\|StreamDataSortDirection" /Users/reimar/dev/meshmakers/branches/main/octo-construction-kit-engine-mongodb/src/Runtime.Engine.MongoDb/StreamData/CrateDbStreamDataRepository.cs
```

- [ ] **Step 2: Replace each reference**

- `StreamDataSortOrder` → `SortOrderItem`, property `.Direction` → `.SortOrder` (enum values stay `Ascending/Descending`; ignore `Default`)
- `StreamDataFieldFilter` → `FieldFilter`, property `.Value` → `.ComparisonValue`
- `StreamDataAggregationColumn` → `AggregationColumn` (property names unchanged: `AttributePath`, `Function`)
- Add using: `using Meshmakers.Octo.Runtime.Contracts.Repositories.Query;`
- Add using for CK-generated `AggregationTypes`: `using Meshmakers.Octo.ConstructionKit.Models.System.Generated.System.v2;`

For aggregation function mapping to CrateDB SQL, handle the new enum values:

```csharp
private static string MapAggregationToSql(AggregationTypes fn) => fn switch
{
    AggregationTypes.Count   => "COUNT",
    AggregationTypes.Minimum => "MIN",
    AggregationTypes.Maximum => "MAX",
    AggregationTypes.Average => "AVG",
    AggregationTypes.Sum     => "SUM",
    _ => throw new ArgumentOutOfRangeException(nameof(fn), fn, "Unknown aggregation function")
};
```

- [ ] **Step 3: Build engine-mongodb**

```bash
dotnet build /Users/reimar/dev/meshmakers/branches/main/octo-construction-kit-engine-mongodb -c DebugL 2>&1 | tail -15
```

Expected: compiles green.

- [ ] **Step 4: Commit**

```bash
git -C /Users/reimar/dev/meshmakers/branches/main/octo-construction-kit-engine-mongodb add src/Runtime.Engine.MongoDb/StreamData/CrateDbStreamDataRepository.cs
git -C /Users/reimar/dev/meshmakers/branches/main/octo-construction-kit-engine-mongodb commit -m "Update CrateDbStreamDataRepository to shared RT query types

Uses SortOrderItem, FieldFilter, AggregationColumn, AggregationTypes
in place of the deprecated stream-specific duplicates.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

### Task 1.4: Add CrateDB operator mapper with `Between` support (TDD)

**Files:**
- Create: `octo-construction-kit-engine-mongodb/tests/StreamData.UnitTests/CrateDbFieldFilterMapperTests.cs`
- Modify: `octo-construction-kit-engine-mongodb/src/Runtime.Engine.MongoDb/StreamData/CrateDbStreamDataRepository.cs` (add mapper helper)

- [ ] **Step 1: Write the failing test**

```csharp
using Meshmakers.Octo.Runtime.Contracts.Repositories.Query;
using Meshmakers.Octo.Runtime.Engine.MongoDb.StreamData;

namespace Meshmakers.Octo.Runtime.Engine.MongoDb.StreamData.UnitTests;

public class CrateDbFieldFilterMapperTests
{
    [Fact]
    public void Equals_EmitsEqualsSql()
    {
        var filter = new FieldFilter("Voltage", FieldFilterOperator.Equals, 220);
        var (sql, _) = CrateDbFieldFilterMapper.ToSql(filter, isDataField: true);
        Assert.Contains("data['Voltage']", sql);
        Assert.Contains(" = ", sql);
    }

    [Fact]
    public void Between_EmitsBetweenSqlWithBothValues()
    {
        var from = new DateTime(2026, 1, 1, 0, 0, 0, DateTimeKind.Utc);
        var to   = new DateTime(2026, 1, 2, 0, 0, 0, DateTimeKind.Utc);
        var filter = new FieldFilter("Timestamp", FieldFilterOperator.Between, from, to);
        var (sql, _) = CrateDbFieldFilterMapper.ToSql(filter, isDataField: false);
        Assert.Contains("BETWEEN", sql);
        Assert.Contains("2026-01-01", sql);
        Assert.Contains("2026-01-02", sql);
    }

    [Fact]
    public void MatchRegEx_Throws()
    {
        var filter = new FieldFilter("X", FieldFilterOperator.MatchRegEx, "foo");
        Assert.Throws<NotSupportedException>(() => CrateDbFieldFilterMapper.ToSql(filter, isDataField: true));
    }

    [Fact]
    public void Contains_Throws()
    {
        var filter = new FieldFilter("X", FieldFilterOperator.Contains, "foo");
        Assert.Throws<NotSupportedException>(() => CrateDbFieldFilterMapper.ToSql(filter, isDataField: true));
    }
}
```

- [ ] **Step 2: Run test — expect compile failure (mapper doesn't exist)**

```bash
dotnet test /Users/reimar/dev/meshmakers/branches/main/octo-construction-kit-engine-mongodb/tests/StreamData.UnitTests -c DebugL 2>&1 | tail -10
```

Expected: build error `CrateDbFieldFilterMapper` not found.

- [ ] **Step 3: Implement the mapper as an internal static class**

Create or locate the method. Add as `internal static class CrateDbFieldFilterMapper` in `CrateDbStreamDataRepository.cs` (same file, private-to-assembly helper) or in a sibling file `CrateDbFieldFilterMapper.cs` in the same folder:

```csharp
internal static class CrateDbFieldFilterMapper
{
    public static (string Sql, object? Param) ToSql(FieldFilter f, bool isDataField)
    {
        var column = isDataField
            ? $"\"data['{f.AttributePath}']\""
            : $"\"{f.AttributePath}\"";

        return f.Operator switch
        {
            FieldFilterOperator.Equals            => ($"{column} = '{Escape(f.ComparisonValue)}'", null),
            FieldFilterOperator.NotEquals         => ($"{column} != '{Escape(f.ComparisonValue)}'", null),
            FieldFilterOperator.LessThan          => ($"{column} < '{Escape(f.ComparisonValue)}'", null),
            FieldFilterOperator.LessEqualThan     => ($"{column} <= '{Escape(f.ComparisonValue)}'", null),
            FieldFilterOperator.GreaterThan       => ($"{column} > '{Escape(f.ComparisonValue)}'", null),
            FieldFilterOperator.GreaterEqualThan  => ($"{column} >= '{Escape(f.ComparisonValue)}'", null),
            FieldFilterOperator.Like              => ($"{column} LIKE '{Escape(f.ComparisonValue)}'", null),
            FieldFilterOperator.In                => ($"{column} IN ({FormatList(f.ComparisonValue)})", null),
            FieldFilterOperator.NotIn             => ($"{column} NOT IN ({FormatList(f.ComparisonValue)})", null),
            FieldFilterOperator.IsNull            => ($"{column} IS NULL", null),
            FieldFilterOperator.IsNotNull         => ($"{column} IS NOT NULL", null),
            FieldFilterOperator.Between           => ($"{column} BETWEEN '{FormatValue(f.ComparisonValue)}' AND '{FormatValue(f.SecondaryValue)}'", null),
            _ => throw new NotSupportedException($"Operator {f.Operator} not supported for stream data queries against CrateDB")
        };
    }

    private static string Escape(object? v) => v?.ToString()?.Replace("'", "''") ?? "";
    private static string FormatValue(object? v) => v switch
    {
        DateTime dt => dt.ToString("yyyy-MM-dd HH:mm:ss.fffZ"),
        _ => Escape(v)
    };
    private static string FormatList(object? v)
    {
        if (v is System.Collections.IEnumerable e && v is not string)
            return string.Join(", ", e.Cast<object>().Select(x => $"'{Escape(x)}'"));
        return $"'{Escape(v)}'";
    }
}
```

Wire this mapper into the places inside `CrateDbStreamDataRepository` where `FieldFilter` was previously translated via `CrateQueryBuilder.AddFieldFilter`. Replace those sites with `CrateDbFieldFilterMapper.ToSql(...)` + direct WHERE-clause emission on the internal builder.

- [ ] **Step 4: Run tests**

```bash
dotnet test /Users/reimar/dev/meshmakers/branches/main/octo-construction-kit-engine-mongodb/tests/StreamData.UnitTests -c DebugL 2>&1 | tail -8
```

Expected: all tests pass (new 4 + existing 51).

- [ ] **Step 5: Commit**

```bash
git -C /Users/reimar/dev/meshmakers/branches/main/octo-construction-kit-engine-mongodb add src/Runtime.Engine.MongoDb/StreamData/ tests/StreamData.UnitTests/CrateDbFieldFilterMapperTests.cs
git -C /Users/reimar/dev/meshmakers/branches/main/octo-construction-kit-engine-mongodb commit -m "Add CrateDB field-filter operator mapper with Between support

Covers the supported subset (Equals/NotEquals/LT/LTE/GT/GTE/Like/In/NotIn/
IsNull/IsNotNull/Between). Throws NotSupportedException for unsupported
MongoDB-specific operators (MatchRegEx, Contains, StartsWith, etc).

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

### Task 1.5: Update `StreamDataGraphQlMapper` to shared RT types

**Files:**
- Modify: `octo-asset-repo-services/src/AssetRepositoryServices/GraphQL/StreamDataGraphQlMapper.cs`

The mapper currently converts GraphQL DTOs (`SortDto`, `FieldFilterDto`, `AggregationInputTypesDto`) to the engine types. Those engine target types are now `SortOrderItem` / `FieldFilter` / `AggregationColumn`.

- [ ] **Step 1: Rewrite mapper methods to emit shared RT types**

```csharp
public static IReadOnlyList<SortOrderItem>? MapSortOrders(IEnumerable<SortDto>? dtos) =>
    dtos?.Select(d => new SortOrderItem(d.AttributePath, MapSortDirection(d.SortOrder))).ToList();

private static SortOrders MapSortDirection(SortOrdersDto? d) => d switch
{
    SortOrdersDto.AscendingDto  => SortOrders.Ascending,
    SortOrdersDto.DescendingDto => SortOrders.Descending,
    _ => SortOrders.Default
};

public static IReadOnlyList<FieldFilter>? MapFieldFilters(IEnumerable<FieldFilterDto>? dtos) =>
    dtos?.Select(d => new FieldFilter(
        d.AttributePath,
        MapFieldFilterOperator(d.Operator),
        d.ComparisonValue,
        d.SecondaryValue)).ToList();

public static AggregationTypes MapAggregationFunctionDto(AggregationInputTypesDto d) => d switch
{
    AggregationInputTypesDto.CountDto   => AggregationTypes.Count,
    AggregationInputTypesDto.MinimumDto => AggregationTypes.Minimum,
    AggregationInputTypesDto.MaximumDto => AggregationTypes.Maximum,
    AggregationInputTypesDto.AverageDto => AggregationTypes.Average,
    AggregationInputTypesDto.SumDto     => AggregationTypes.Sum,
    _ => throw new ArgumentOutOfRangeException(nameof(d), d, "Unknown aggregation function")
};
```

Delete or rewrite the `MapCkAggregationType`, `MapCkFieldFilters<T>`, `MapCkSortOrders<T>` helpers that referenced the deleted stream enums/records; the persistent-query resolvers in `StreamDataQuery.cs` will use these new signatures in Task 1.6.

Check `FieldFilterDto` actually carries `SecondaryValue`. If it doesn't, add the field to the GraphQL input DTO type (`FieldFilterDtoType.cs`) and the C# DTO record (`FieldFilterDto.cs`) in the same repo.

- [ ] **Step 2: Build asset-repo — expect compilation errors in `StreamDataQuery.cs`**

```bash
dotnet build /Users/reimar/dev/meshmakers/branches/main/octo-asset-repo-services -c DebugL 2>&1 | tail -20
```

Expected: errors in `StreamDataQuery.cs` where the old mapper signatures were called. That's OK — Task 1.6 fixes them.

### Task 1.6: Update `StreamDataQuery.cs` call sites to new mapper/option signatures

**Files:**
- Modify: `octo-asset-repo-services/src/AssetRepositoryServices/GraphQL/StreamDataQuery.cs`

- [ ] **Step 1: Compile and iterate on errors**

```bash
dotnet build /Users/reimar/dev/meshmakers/branches/main/octo-asset-repo-services -c DebugL 2>&1 | grep error | head -30
```

For each error, update the call site: `StreamDataSortOrder` → `SortOrderItem`, `StreamDataFieldFilter` → `FieldFilter`, `StreamDataAggregationColumn` → `AggregationColumn`, `StreamDataAggregationFunction.X` → `AggregationTypes.X`. The `StreamDataGraphQlMapper.Map*` signatures match the new shapes.

- [ ] **Step 2: Build green**

```bash
dotnet build /Users/reimar/dev/meshmakers/branches/main/octo-asset-repo-services -c DebugL 2>&1 | tail -10
```

Expected: build succeeds.

- [ ] **Step 3: Run asset-repo unit tests**

```bash
dotnet test /Users/reimar/dev/meshmakers/branches/main/octo-asset-repo-services/tests/AssetRepositoryServices.UnitTests -c DebugL --no-build 2>&1 | tail -5
```

Expected: 44/44 pass.

- [ ] **Step 4: Run stream integration tests**

```bash
dotnet test /Users/reimar/dev/meshmakers/branches/main/octo-asset-repo-services/tests/AssetRepositoryServices.IntegrationTests -c DebugL --no-build --filter "FullyQualifiedName~StreamData" 2>&1 | tail -5
```

Expected: all stream integration tests pass.

- [ ] **Step 5: Commit**

```bash
git -C /Users/reimar/dev/meshmakers/branches/main/octo-asset-repo-services add src/AssetRepositoryServices/GraphQL/
git -C /Users/reimar/dev/meshmakers/branches/main/octo-asset-repo-services commit -m "Rewire StreamDataQuery.cs to shared RT query types

StreamDataGraphQlMapper now returns SortOrderItem/FieldFilter/AggregationColumn.
Resolver call sites updated to match. Asset-repo integration tests green.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

### Task 1.7: Delete stream-specific duplicate types

**Files:**
- Delete: `octo-construction-kit-engine/src/Runtime.Contracts/StreamData/StreamDataSortOrder.cs`
- Delete: `octo-construction-kit-engine/src/Runtime.Contracts/StreamData/StreamDataFieldFilter.cs`
- Delete: `octo-construction-kit-engine/src/Runtime.Contracts/StreamData/StreamDataAggregationColumn.cs`
- Modify: `octo-construction-kit-engine/src/Runtime.Contracts/StreamData/StreamDataEnums.cs` — delete the three enums (`StreamDataSortDirection`, `StreamDataFieldFilterOperator`, `StreamDataAggregationFunction`). Delete the whole file if it becomes empty.

- [ ] **Step 1: Grep for any remaining references across all repos**

```bash
for repo in octo-construction-kit-engine octo-construction-kit-engine-mongodb octo-common-services octo-asset-repo-services octo-mesh-adapter octo-sdk; do
  grep -rn "StreamDataSortOrder\|StreamDataFieldFilter\|StreamDataAggregationColumn\|StreamDataAggregationFunction\|StreamDataFieldFilterOperator\|StreamDataSortDirection" /Users/reimar/dev/meshmakers/branches/main/$repo/src /Users/reimar/dev/meshmakers/branches/main/$repo/tests 2>/dev/null | grep -v "/obj/" | grep -v "/bin/"
done
```

Expected: zero hits. If any remain, fix them first.

- [ ] **Step 2: Delete the files**

```bash
rm /Users/reimar/dev/meshmakers/branches/main/octo-construction-kit-engine/src/Runtime.Contracts/StreamData/StreamDataSortOrder.cs
rm /Users/reimar/dev/meshmakers/branches/main/octo-construction-kit-engine/src/Runtime.Contracts/StreamData/StreamDataFieldFilter.cs
rm /Users/reimar/dev/meshmakers/branches/main/octo-construction-kit-engine/src/Runtime.Contracts/StreamData/StreamDataAggregationColumn.cs
rm /Users/reimar/dev/meshmakers/branches/main/octo-construction-kit-engine/src/Runtime.Contracts/StreamData/StreamDataEnums.cs
```

- [ ] **Step 3: Build all affected repos in order**

```bash
dotnet build /Users/reimar/dev/meshmakers/branches/main/octo-construction-kit-engine -c DebugL 2>&1 | tail -5
dotnet build /Users/reimar/dev/meshmakers/branches/main/octo-construction-kit-engine-mongodb -c DebugL 2>&1 | tail -5
dotnet build /Users/reimar/dev/meshmakers/branches/main/octo-asset-repo-services -c DebugL 2>&1 | tail -5
dotnet build /Users/reimar/dev/meshmakers/branches/main/octo-mesh-adapter -c DebugL 2>&1 | tail -5
```

Expected: all green.

- [ ] **Step 4: Run all relevant test suites**

```bash
dotnet test /Users/reimar/dev/meshmakers/branches/main/octo-construction-kit-engine-mongodb/tests/StreamData.UnitTests -c DebugL --no-build 2>&1 | tail -3
dotnet test /Users/reimar/dev/meshmakers/branches/main/octo-asset-repo-services/tests/AssetRepositoryServices.UnitTests -c DebugL --no-build 2>&1 | tail -3
dotnet test /Users/reimar/dev/meshmakers/branches/main/octo-asset-repo-services/tests/AssetRepositoryServices.IntegrationTests -c DebugL --no-build --filter "FullyQualifiedName~StreamData" 2>&1 | tail -3
dotnet test /Users/reimar/dev/meshmakers/branches/main/octo-mesh-adapter/tests/MeshAdapter.Sdk.Tests -c DebugL --no-build 2>&1 | tail -3
```

Expected: all green.

- [ ] **Step 5: Commit engine deletions**

```bash
git -C /Users/reimar/dev/meshmakers/branches/main/octo-construction-kit-engine add -A src/Runtime.Contracts/StreamData/
git -C /Users/reimar/dev/meshmakers/branches/main/octo-construction-kit-engine commit -m "Delete stream-specific enums and records superseded by shared RT types

StreamDataSortOrder, StreamDataFieldFilter, StreamDataAggregationColumn
and their three enum companions are replaced by SortOrderItem, FieldFilter,
AggregationColumn, SortOrders, FieldFilterOperator, AggregationTypes.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

### Task 1.8: Phase 1 verification — integration test for `Between`

**Files:**
- Create: `octo-asset-repo-services/tests/AssetRepositoryServices.IntegrationTests/StreamData/StreamDataBetweenFilterTests.cs`

- [ ] **Step 1: Write an integration test exercising Between on Timestamp**

```csharp
using GraphQL;
using Meshmakers.Octo.Backend.AssetRepositoryServices.IntegrationTests.Fixtures;

namespace Meshmakers.Octo.Backend.AssetRepositoryServices.IntegrationTests.StreamData;

public class StreamDataBetweenFilterTests(StreamDataFixture fixture)
    : IClassFixture<StreamDataFixture>
{
    [Fact]
    public async Task TransientStreamDataQuery_WithBetweenTimestampFilter_ReturnsExpectedRange()
    {
        const string query = """
            query {
                StreamData {
                    TransientStreamDataQuery(
                        ckId: "AssetRepositoryIntegrationTest/MeteringPoint"
                        columnPaths: ["Voltage"]
                        fieldFilter: [{
                            attributePath: "Timestamp"
                            operator: BETWEEN
                            comparisonValue: "2026-01-01T10:00:00Z"
                            secondaryValue: "2026-01-01T10:15:00Z"
                        }]
                    ) {
                        edges { node { cells { attributePath, value } } }
                    }
                }
            }
        """;
        var result = await fixture.ExecuteGraphQlAsync(query);
        Assert.Null(result.Errors);
        // 20 points spanning 3-min intervals from 10:00 — Between 10:00 and 10:15 inclusive includes points at 10:00, 10:03, 10:06, 10:09, 10:12, 10:15 = 6 rows
        var json = fixture.SerializeGraphQl(result);
        Assert.Contains("\"Voltage\"", json);
    }
}
```

- [ ] **Step 2: Run the test**

```bash
dotnet test /Users/reimar/dev/meshmakers/branches/main/octo-asset-repo-services/tests/AssetRepositoryServices.IntegrationTests -c DebugL --filter "FullyQualifiedName~Between" 2>&1 | tail -5
```

Expected: PASS. If FAIL, debug the GraphQL surface — `FieldFilterDto` might not yet carry `secondaryValue` on the GraphQL side. Add it in `FieldFilterDtoType` (GraphQL input) and `FieldFilterDto` (C# DTO) if missing.

- [ ] **Step 3: Commit**

```bash
git -C /Users/reimar/dev/meshmakers/branches/main/octo-asset-repo-services add tests/AssetRepositoryServices.IntegrationTests/StreamData/StreamDataBetweenFilterTests.cs src/AssetRepositoryServices/GraphQL/Types/Inputs/FieldFilterDtoType.cs 2>/dev/null || true
git -C /Users/reimar/dev/meshmakers/branches/main/octo-asset-repo-services commit -m "Add Between timestamp-filter integration test for stream data

Covers the new shared-FieldFilter operator supported by CrateDB via BETWEEN.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

---

## Phase 2 — CK model alignment

Renames stream-data query CK types to the `*SdQuery` convention; introduces abstract `StreamDataQuery` base with shared attributes.

### Task 2.1: Edit the System CK model YAML

**Files:**
- Modify: `octo-construction-kit-engine/src/SystemCkModel/ConstructionKit/ckModel.yaml` (version bump)
- Modify: `octo-construction-kit-engine/src/SystemCkModel/ConstructionKit/types/query.yaml`

Decision: bump the **patch** version only (`System-2.0.8` → `System-2.0.9`). Downstream CK models that depend on `System-[2.0,)` continue to resolve. No formal CK migration script is written and no database operation is performed in this plan — any local cleanup is up to the dev machine owner. This is acceptable because no customer is actively using stream-data queries.

- [ ] **Step 0: Bump the CK model version**

In `ckModel.yaml`:

```diff
- modelId: "System-2.0.8"
+ modelId: "System-2.0.9"
```

- [ ] **Step 1: Rewrite the four stream query types + add the abstract base**

Replace the four `StreamData*Query` blocks (lines 75-168) with:

```yaml
  - typeId: StreamDataQuery
    description: "Abstract base for all stream-data query types. Defines the common time-range, limit, rtId scope, and filter attributes shared by all stream-data query variants."
    derivedFromCkTypeId: ${this}/PersistentQuery
    isFinal: false
    isAbstract: true
    attributes:
      - id: ${this}/StreamDataQuery.RtIds
        name: RtIds
        isOptional: true
      - id: ${this}/StreamDataQuery.From
        name: From
        isOptional: true
      - id: ${this}/StreamDataQuery.To
        name: To
        isOptional: true
      - id: ${this}/StreamDataQuery.Limit
        name: Limit
        isOptional: true
      - id: ${this}/Query.FieldFilter
        name: FieldFilter
        isOptional: true
  - typeId: SimpleSdQuery
    description: "Persistent stream-data query that retrieves time-series data for a given CK type with optional column projection, sorting, and field filters."
    derivedFromCkTypeId: ${this}/StreamDataQuery
    isFinal: false
    isAbstract: false
    attributes:
      - id: ${this}/StreamDataQuery.Columns
        name: Columns
      - id: ${this}/Query.Sorting
        name: Sorting
        isOptional: true
  - typeId: AggregationSdQuery
    description: "Persistent stream-data query that performs aggregation operations (Count/Min/Max/Avg/Sum) on time-series data without grouping."
    derivedFromCkTypeId: ${this}/StreamDataQuery
    isFinal: false
    isAbstract: false
    attributes:
      - id: ${this}/AggregationQueryColumns
        name: Columns
  - typeId: GroupingAggregationSdQuery
    description: "Persistent stream-data query that performs grouped aggregation with GROUP BY functionality on time-series data."
    derivedFromCkTypeId: ${this}/StreamDataQuery
    isFinal: false
    isAbstract: false
    attributes:
      - id: ${this}/Query.GroupByColumns
        name: GroupingColumns
      - id: ${this}/AggregationQueryColumns
        name: Columns
  - typeId: DownsamplingSdQuery
    description: "Persistent stream-data query that downsamples time-series data using DATE_BIN bucketing with per-column aggregation. Requires From, To, and Limit (bucket count)."
    derivedFromCkTypeId: ${this}/StreamDataQuery
    isFinal: false
    isAbstract: false
    attributes:
      - id: ${this}/AggregationQueryColumns
        name: Columns
```

Note: `From`, `To`, `Limit` are optional on the base for Simple/Aggregation/Grouping. For `DownsamplingSdQuery` these are required at the API/resolver level (enforced in code, not YAML, because YAML inheritance doesn't support tightening optionality cleanly).

- [ ] **Step 2: Rebuild the CK model**

```bash
dotnet build /Users/reimar/dev/meshmakers/branches/main/octo-construction-kit-engine/src/SystemCkModel -c DebugL 2>&1 | tail -10
```

Expected: CK compilation succeeds; regenerated C# includes `RtStreamDataQuery` (abstract), `RtSimpleSdQuery`, `RtAggregationSdQuery`, `RtGroupingAggregationSdQuery`, `RtDownsamplingSdQuery`.

- [ ] **Step 3: Verify generated classes exist**

```bash
find /Users/reimar/dev/meshmakers/branches/main/octo-construction-kit-engine/src/SystemCkModel/obj -name "*.cs" 2>/dev/null | xargs grep -l "class RtSimpleSdQuery\|class RtStreamDataQuery" 2>/dev/null | head -3
```

Expected: one or more hits.

- [ ] **Step 4: Commit CK YAML change (builds alone, downstream won't compile yet)**

```bash
git -C /Users/reimar/dev/meshmakers/branches/main/octo-construction-kit-engine add src/SystemCkModel/ConstructionKit/ckModel.yaml src/SystemCkModel/ConstructionKit/types/query.yaml
git -C /Users/reimar/dev/meshmakers/branches/main/octo-construction-kit-engine commit -m "Rename stream-data CK query types to *SdQuery with shared abstract base

Introduces abstract StreamDataQuery carrying RtIds/From/To/Limit/FieldFilter.
Subtypes SimpleSdQuery, AggregationSdQuery, GroupingAggregationSdQuery,
DownsamplingSdQuery mirror the *RtQuery convention on the runtime side.

Bumps System CK model version 2.0.8 -> 2.0.9 (patch). No formal migration
script and no database operation: no customer is actively using stream-data
queries and any local dev cleanup is owner-handled.

Downstream consumers (asset-repo resolvers, integration tests) are
updated in follow-up commits.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

### Task 2.2: Update asset-repo resolver generic args

**Files:**
- Modify: `octo-asset-repo-services/src/AssetRepositoryServices/GraphQL/StreamDataQuery.cs`

- [ ] **Step 1: Replace generic type arguments in `GetRtEntityByRtIdAsync<...>`**

Find every occurrence of `RtStreamData{Variant}Query` in `StreamDataQuery.cs` and rename:

| Old | New |
|---|---|
| `RtStreamDataSimpleQuery` | `RtSimpleSdQuery` |
| `RtStreamDataAggregationQuery` | `RtAggregationSdQuery` |
| `RtStreamDataGroupingAggregationQuery` | `RtGroupingAggregationSdQuery` |
| `RtStreamDataDownsamplingQuery` | `RtDownsamplingSdQuery` |

Use sed for batch rename:

```bash
cd /Users/reimar/dev/meshmakers/branches/main/octo-asset-repo-services
sed -i '' 's/RtStreamDataSimpleQuery/RtSimpleSdQuery/g; s/RtStreamDataAggregationQuery/RtAggregationSdQuery/g; s/RtStreamDataGroupingAggregationQuery/RtGroupingAggregationSdQuery/g; s/RtStreamDataDownsamplingQuery/RtDownsamplingSdQuery/g' src/AssetRepositoryServices/GraphQL/StreamDataQuery.cs
```

- [ ] **Step 2: Build**

```bash
dotnet build /Users/reimar/dev/meshmakers/branches/main/octo-asset-repo-services -c DebugL 2>&1 | tail -10
```

Expected: green.

- [ ] **Step 3: Commit**

```bash
git -C /Users/reimar/dev/meshmakers/branches/main/octo-asset-repo-services add src/AssetRepositoryServices/GraphQL/StreamDataQuery.cs
git -C /Users/reimar/dev/meshmakers/branches/main/octo-asset-repo-services commit -m "Rename stream-data query C# types to Rt*SdQuery in resolver

Matches the CK YAML rename. No behavior change.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

### Task 2.3: Update integration test fixtures and test data

**Files:**
- Modify: `octo-asset-repo-services/tests/AssetRepositoryServices.IntegrationTests/Fixtures/StreamDataFixture.cs`
- Modify: `octo-asset-repo-services/tests/AssetRepositoryServices.IntegrationTests/StreamData/*.cs`
- Modify: `octo-asset-repo-services/tests/AssetRepositoryIntegrationTestCkModel/ConstructionKit/` (if any test CK model references the old type names)

- [ ] **Step 1: Grep for old names in tests**

```bash
grep -rn "RtStreamDataSimpleQuery\|RtStreamDataAggregationQuery\|RtStreamDataGroupingAggregationQuery\|RtStreamDataDownsamplingQuery\|StreamDataSimpleQuery\|StreamDataAggregationQuery\|StreamDataGroupingAggregationQuery\|StreamDataDownsamplingQuery" /Users/reimar/dev/meshmakers/branches/main/octo-asset-repo-services/tests 2>/dev/null | grep -v "/obj/" | grep -v "/bin/"
```

- [ ] **Step 2: Rename each occurrence (same mapping as Task 2.2)**

Apply the sed rename across the tests folder:

```bash
find /Users/reimar/dev/meshmakers/branches/main/octo-asset-repo-services/tests -name "*.cs" -type f | \
  xargs sed -i '' 's/RtStreamDataSimpleQuery/RtSimpleSdQuery/g; s/RtStreamDataAggregationQuery/RtAggregationSdQuery/g; s/RtStreamDataGroupingAggregationQuery/RtGroupingAggregationSdQuery/g; s/RtStreamDataDownsamplingQuery/RtDownsamplingSdQuery/g'
```

Also search YAML fixtures:
```bash
grep -rn "StreamDataSimpleQuery\|StreamDataAggregationQuery\|StreamDataGroupingAggregationQuery\|StreamDataDownsamplingQuery" /Users/reimar/dev/meshmakers/branches/main/octo-asset-repo-services/tests --include="*.yaml" 2>/dev/null
```

If any YAML fixtures reference the old names, update them to `SimpleSdQuery` / `AggregationSdQuery` / `GroupingAggregationSdQuery` / `DownsamplingSdQuery`.

- [ ] **Step 3: Grep downstream CK model packages too**

```bash
grep -rn "StreamDataSimpleQuery\|StreamDataAggregationQuery\|StreamDataGroupingAggregationQuery\|StreamDataDownsamplingQuery" /Users/reimar/dev/meshmakers/branches/main/octo-construction-kit 2>/dev/null | grep -v "/obj/" | grep -v "/bin/"
```

If hits found, update those CK packages too (same rename).

- [ ] **Step 4: Build and test**

```bash
dotnet build /Users/reimar/dev/meshmakers/branches/main/octo-asset-repo-services -c DebugL 2>&1 | tail -5
dotnet test /Users/reimar/dev/meshmakers/branches/main/octo-asset-repo-services/tests/AssetRepositoryServices.IntegrationTests -c DebugL --no-build --filter "FullyQualifiedName~StreamData" 2>&1 | tail -5
```

Expected: all green.

- [ ] **Step 5: Commit**

```bash
git -C /Users/reimar/dev/meshmakers/branches/main/octo-asset-repo-services add tests/
git -C /Users/reimar/dev/meshmakers/branches/main/octo-asset-repo-services commit -m "Rename stream-data query types in integration tests to Rt*SdQuery

Matches the CK YAML and resolver rename. Integration tests green.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

### Task 2.4: Local data cleanup (user-owned)

No database operations prescribed. The dev machine owner handles local MongoDB state manually as they see fit — e.g. ignore orphaned old-type query documents, or surgically delete just the stream-data query entities if they prefer a clean state. Integration tests run against fresh Testcontainers-managed databases per test class, so they are unaffected.

---

## Phase 3 — Source generator + `SdEntity`

Adds the `SdEntity` base class and extends source generators to emit typed `Sd{CkType}` classes plus their GraphQL DTO types. No GraphQL surface wiring yet.

### Task 3.1: Add `SdEntity` base class

**Files:**
- Create: `octo-construction-kit-engine/src/Runtime.Contracts/StreamData/SdEntity.cs`

- [ ] **Step 1: Create the class**

```csharp
using Meshmakers.Octo.ConstructionKit.Contracts;

namespace Meshmakers.Octo.Runtime.Contracts.StreamData;

/// <summary>
///     Base class for stream-data entity projections. Subclasses are emitted per CK type that has
///     <c>isDataStream</c> attributes; they expose typed properties for those attributes plus the
///     built-in stream fields (Timestamp, RtId, CkTypeId, RtWellKnownName, RtCreationDateTime,
///     RtChangedDateTime).
/// </summary>
public abstract class SdEntity
{
    /// <summary>Runtime id of the entity this data point belongs to.</summary>
    public OctoObjectId RtId { get; set; }

    /// <summary>CK type id of the entity this data point belongs to.</summary>
    public RtCkId<CkTypeId> CkTypeId { get; set; } = null!;

    /// <summary>Timestamp of this data point (time-series position).</summary>
    public DateTime Timestamp { get; set; }

    /// <summary>Well-known name of the entity, if any.</summary>
    public string? RtWellKnownName { get; set; }

    /// <summary>When the source entity was originally created.</summary>
    public DateTime? RtCreationDateTime { get; set; }

    /// <summary>When the source entity was last modified.</summary>
    public DateTime? RtChangedDateTime { get; set; }

    /// <summary>
    ///     Raw attribute bag. Contains every attribute value present on the row, including those not
    ///     mapped to typed properties. Stays populated even when typed properties are in use.
    /// </summary>
    public AttributesCollection Attributes { get; set; } = new();
}
```

If `AttributesCollection` lives in a different namespace, add its using. Pattern-match on `RtEntity.Attributes` to find the correct type and using.

- [ ] **Step 2: Build**

```bash
dotnet build /Users/reimar/dev/meshmakers/branches/main/octo-construction-kit-engine -c DebugL 2>&1 | tail -5
```

Expected: green.

- [ ] **Step 3: Commit**

```bash
git -C /Users/reimar/dev/meshmakers/branches/main/octo-construction-kit-engine add src/Runtime.Contracts/StreamData/SdEntity.cs
git -C /Users/reimar/dev/meshmakers/branches/main/octo-construction-kit-engine commit -m "Add SdEntity base class for typed stream-data projections

Sibling of RtEntity but with Timestamp in place of RtCreationDateTime/
RtChangedDateTime. Will be the base for source-generated Sd{CkType}
classes.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

### Task 3.2: Extend `CkTypeCodeGenerator` to emit `Sd{CkType}` classes

**Files:**
- Modify: `octo-construction-kit-engine/src/ConstructionKit.SourceGeneration/CkTypeCodeGenerator.cs`

- [ ] **Step 1: Understand the existing generator output**

Read `CkTypeCodeGenerator.cs` fully. Today it emits `Rt{CkType} : RtEntity` with properties for every attribute, and a DI registration. Keep that behavior; add a second emission pass.

- [ ] **Step 2: Add the `Sd{CkType}` emission**

At the bottom of the generator's per-type emission, check whether any attribute on the CK type has `IsDataStream == true`. If so, emit a second class:

```csharp
bool hasDataStream = attributes.Any(a => a.IsDataStream);
if (hasDataStream)
{
    sb.AppendLine();
    sb.AppendLine($"public class Sd{typeName} : Meshmakers.Octo.Runtime.Contracts.StreamData.SdEntity");
    sb.AppendLine("{");
    foreach (var attr in attributes.Where(a => a.IsDataStream))
    {
        var propType = MapCkValueTypeToCSharp(attr.ValueType);  // existing helper
        sb.AppendLine($"    public {propType}? {attr.AttributeName} {{ get; set; }}");
    }
    sb.AppendLine("}");
}
```

Use whatever the existing helper is for C# type mapping — copy the pattern used by the RT class emission.

- [ ] **Step 3: Build the engine so the generator gets rebuilt**

```bash
dotnet build /Users/reimar/dev/meshmakers/branches/main/octo-construction-kit-engine/src/ConstructionKit.SourceGeneration -c DebugL 2>&1 | tail -5
```

- [ ] **Step 4: Rebuild a CK model that has `isDataStream` attributes and verify generated output**

```bash
dotnet build /Users/reimar/dev/meshmakers/branches/main/octo-construction-kit-engine/src/SystemCkModel -c DebugL 2>&1 | tail -5
find /Users/reimar/dev/meshmakers/branches/main/octo-construction-kit-engine/src/SystemCkModel/obj -name "*.cs" | xargs grep -l "class Sd" 2>/dev/null | head -3
```

The System CK model may not have stream attributes itself. For a direct smoke test, rebuild the asset-repo integration test CK model which does:

```bash
dotnet build /Users/reimar/dev/meshmakers/branches/main/octo-asset-repo-services/tests/AssetRepositoryIntegrationTestCkModel -c DebugL 2>&1 | tail -5
find /Users/reimar/dev/meshmakers/branches/main/octo-asset-repo-services/tests/AssetRepositoryIntegrationTestCkModel/obj -name "*.cs" | xargs grep -n "class Sd" 2>/dev/null | head -3
```

Expected: generated `SdMeteringPoint` class appears.

- [ ] **Step 5: Commit**

```bash
git -C /Users/reimar/dev/meshmakers/branches/main/octo-construction-kit-engine add src/ConstructionKit.SourceGeneration/
git -C /Users/reimar/dev/meshmakers/branches/main/octo-construction-kit-engine commit -m "Emit Sd{CkType} classes for stream-data attributes in CK source generator

For every CK type with isDataStream attributes, the generator now emits
a parallel Sd{CkType} : SdEntity class alongside the existing
Rt{CkType} : RtEntity. Only the isDataStream subset of attributes become
typed properties on the Sd variant.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

### Task 3.3: Extend `QueryDtoCodeGenerator` to emit `Sd{CkType}DtoType`

**Files:**
- Modify: `octo-sdk/src/Sdk.SourceGeneration/QueryDtoCodeGenerator.cs`

- [ ] **Step 1: Read the existing generator to understand the `Rt{CkType}DtoType` emission**

The generator emits GraphQL DTO types (`ObjectGraphType<Rt{CkType}>`) with `Field(d => d.SomeAttr, ...)` lines for each attribute.

- [ ] **Step 2: Add a parallel `Sd{CkType}DtoType` emission**

When the CK type has `isDataStream` attributes, also emit:

Template (using StringBuilder emission as the existing generator does):

```csharp
sb.AppendLine($"public class Sd{typeName}DtoType : ObjectGraphType<Sd{typeName}>");
sb.AppendLine("{");
sb.AppendLine($"    public Sd{typeName}DtoType()");
sb.AppendLine("    {");
sb.AppendLine($"        Name = \"Sd{typeName}\";");
sb.AppendLine($"        Description = \"Stream-data projection of {typeName}\";");
sb.AppendLine("        Field(d => d.RtId, typeof(OctoObjectIdType));");
sb.AppendLine("        Field(d => d.CkTypeId, typeof(RtCkIdGraph<CkTypeId>));");
sb.AppendLine("        Field(d => d.Timestamp, typeof(DateTimeGraphType));");
sb.AppendLine("        Field(d => d.RtWellKnownName, nullable: true);");
sb.AppendLine("        Field(d => d.RtCreationDateTime, typeof(DateTimeGraphType));");
sb.AppendLine("        Field(d => d.RtChangedDateTime, typeof(DateTimeGraphType));");
foreach (var attr in attributes.Where(a => a.IsDataStream))
{
    var graphType = MapCkValueTypeToGraphQLType(attr.ValueType);  // existing helper — look at the Rt{CkType}DtoType emission to find the exact helper name in this file
    sb.AppendLine($"        Field(d => d.{attr.AttributeName}, typeof({graphType}), nullable: true);");
}
sb.AppendLine("    }");
sb.AppendLine("}");
```

The existing `Rt{CkType}DtoType` emission in the same generator file is the reference pattern — mirror its conventions (using directives, namespace placement, helper method names). The filter changes from "all attributes" to "isDataStream attributes only".

- [ ] **Step 3: Build**

```bash
dotnet build /Users/reimar/dev/meshmakers/branches/main/octo-sdk -c DebugL 2>&1 | tail -5
```

- [ ] **Step 4: Rebuild asset-repo to pick up the new generator output**

```bash
dotnet build /Users/reimar/dev/meshmakers/branches/main/octo-asset-repo-services -c DebugL 2>&1 | tail -5
find /Users/reimar/dev/meshmakers/branches/main/octo-asset-repo-services/tests/AssetRepositoryIntegrationTestCkModel/obj -name "*.cs" | xargs grep -n "class SdMeteringPointDtoType" 2>/dev/null | head -3
```

Expected: generated DTO type appears.

- [ ] **Step 5: Commit**

```bash
git -C /Users/reimar/dev/meshmakers/branches/main/octo-sdk add src/Sdk.SourceGeneration/QueryDtoCodeGenerator.cs
git -C /Users/reimar/dev/meshmakers/branches/main/octo-sdk commit -m "Emit Sd{CkType}DtoType GraphQL types in SDK source generator

Parallel to the existing Rt{CkType}DtoType emission. Used by the per-type
stream connection in the upcoming GraphQL surface refactor.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

### Task 3.4: Implement `HydrateSdEntity<T>` helper (TDD)

**Files:**
- Create: `octo-construction-kit-engine-mongodb/src/Runtime.Engine.MongoDb/StreamData/SdEntityHydrator.cs`
- Create: `octo-construction-kit-engine-mongodb/tests/StreamData.UnitTests/SdEntityHydratorTests.cs`

- [ ] **Step 1: Write the failing unit test**

```csharp
using Meshmakers.Octo.ConstructionKit.Contracts;
using Meshmakers.Octo.Runtime.Contracts.StreamData;

namespace Meshmakers.Octo.Runtime.Engine.MongoDb.StreamData.UnitTests;

public class SdEntityHydratorTests
{
    // Minimal local SdEntity subclass for testing (real ones come from source generator)
    private class SdTestEntity : SdEntity
    {
        public double? Voltage { get; set; }
        public double? Current { get; set; }
    }

    [Fact]
    public void Hydrate_MapsBuiltInFields()
    {
        var rtId = new OctoObjectId("000000000000000000000001");
        var row = new StreamDataRow
        {
            RtId = rtId,
            CkTypeId = new RtCkId<CkTypeId>("Test/Type"),
            Timestamp = new DateTime(2026, 1, 1, 0, 0, 0, DateTimeKind.Utc),
            RtWellKnownName = "wkn",
            RtCreationDateTime = new DateTime(2025, 12, 1, 0, 0, 0, DateTimeKind.Utc),
            RtChangedDateTime = new DateTime(2025, 12, 15, 0, 0, 0, DateTimeKind.Utc),
            Values = new Dictionary<string, object?>()
        };
        var e = SdEntityHydrator.Hydrate<SdTestEntity>(row);
        Assert.Equal(rtId, e.RtId);
        Assert.Equal("Test/Type", e.CkTypeId.Value);
        Assert.Equal(row.Timestamp, e.Timestamp);
        Assert.Equal("wkn", e.RtWellKnownName);
        Assert.Equal(row.RtCreationDateTime, e.RtCreationDateTime);
        Assert.Equal(row.RtChangedDateTime, e.RtChangedDateTime);
    }

    [Fact]
    public void Hydrate_MapsTypedPropertiesFromValues()
    {
        var row = new StreamDataRow
        {
            RtId = OctoObjectId.Empty,
            CkTypeId = new RtCkId<CkTypeId>("Test/Type"),
            Timestamp = DateTime.UtcNow,
            Values = new Dictionary<string, object?> { ["Voltage"] = 220.5, ["Current"] = 10.2 }
        };
        var e = SdEntityHydrator.Hydrate<SdTestEntity>(row);
        Assert.Equal(220.5, e.Voltage);
        Assert.Equal(10.2, e.Current);
    }

    [Fact]
    public void Hydrate_UnknownKeys_StayInAttributes()
    {
        var row = new StreamDataRow
        {
            RtId = OctoObjectId.Empty,
            CkTypeId = new RtCkId<CkTypeId>("Test/Type"),
            Timestamp = DateTime.UtcNow,
            Values = new Dictionary<string, object?> { ["UnknownAttr"] = "xyz" }
        };
        var e = SdEntityHydrator.Hydrate<SdTestEntity>(row);
        Assert.True(e.Attributes.ContainsKey("UnknownAttr"));
    }
}
```

- [ ] **Step 2: Run tests — expect compile failure**

```bash
dotnet test /Users/reimar/dev/meshmakers/branches/main/octo-construction-kit-engine-mongodb/tests/StreamData.UnitTests -c DebugL 2>&1 | tail -5
```

Expected: `SdEntityHydrator` not found.

- [ ] **Step 3: Implement**

```csharp
using System.Reflection;
using Meshmakers.Octo.Runtime.Contracts.StreamData;

namespace Meshmakers.Octo.Runtime.Engine.MongoDb.StreamData;

public static class SdEntityHydrator
{
    private static readonly Dictionary<Type, PropertyInfo[]> _propertyCache = new();

    /// <summary>
    ///     Populates a typed SdEntity from a StreamDataRow. Built-in fields come from the row's
    ///     typed members; dynamic attribute values come from the row's Values dictionary.
    /// </summary>
    public static TEntity Hydrate<TEntity>(StreamDataRow row) where TEntity : SdEntity, new()
    {
        var entity = new TEntity
        {
            RtId = row.RtId ?? default,
            CkTypeId = row.CkTypeId ?? throw new ArgumentException("row.CkTypeId must not be null"),
            Timestamp = row.Timestamp ?? default,
            RtWellKnownName = row.RtWellKnownName,
            RtCreationDateTime = row.RtCreationDateTime,
            RtChangedDateTime = row.RtChangedDateTime
        };

        // Populate Attributes bag with every value (including those mapped to typed props).
        foreach (var kvp in row.Values)
        {
            entity.Attributes[kvp.Key] = kvp.Value;
        }

        // Reflect typed properties declared on the subclass; assign from Values if present.
        var props = _propertyCache.GetOrAdd(typeof(TEntity), t =>
            t.GetProperties(BindingFlags.Instance | BindingFlags.Public | BindingFlags.DeclaredOnly)
             .Where(p => p.CanWrite)
             .ToArray());

        foreach (var prop in props)
        {
            if (row.Values.TryGetValue(prop.Name, out var value) && value != null)
            {
                var target = Nullable.GetUnderlyingType(prop.PropertyType) ?? prop.PropertyType;
                try
                {
                    var converted = Convert.ChangeType(value, target);
                    prop.SetValue(entity, converted);
                }
                catch (InvalidCastException)
                {
                    // Leave as default; value still accessible via Attributes
                }
            }
        }

        return entity;
    }

    private static TValue GetOrAdd<TKey, TValue>(this Dictionary<TKey, TValue> dict, TKey key, Func<TKey, TValue> factory)
        where TKey : notnull
    {
        if (!dict.TryGetValue(key, out var value))
        {
            value = factory(key);
            dict[key] = value;
        }
        return value;
    }
}
```

- [ ] **Step 4: Run tests**

```bash
dotnet test /Users/reimar/dev/meshmakers/branches/main/octo-construction-kit-engine-mongodb/tests/StreamData.UnitTests -c DebugL 2>&1 | tail -5
```

Expected: all tests pass (51 existing + 3 new hydrator tests).

- [ ] **Step 5: Commit**

```bash
git -C /Users/reimar/dev/meshmakers/branches/main/octo-construction-kit-engine-mongodb add src/Runtime.Engine.MongoDb/StreamData/SdEntityHydrator.cs tests/StreamData.UnitTests/SdEntityHydratorTests.cs
git -C /Users/reimar/dev/meshmakers/branches/main/octo-construction-kit-engine-mongodb commit -m "Add SdEntityHydrator for typed Sd{CkType} projection from StreamDataRow

Uses reflection (with a per-type property cache) to copy Values entries
onto typed properties of the subclass. Unknown keys remain in the
Attributes bag.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

---

## Phase 4 — Persistent + transient descriptors

Bundled. Replaces the eight top-level stream roots with one persistent root + one transient namespace, adopting RT's descriptor + sub-connection pattern.

### Task 4.1: Add `StreamDataQueryDto` + descriptor GraphQL type

**Files:**
- Create: `octo-asset-repo-services/src/AssetRepositoryServices/GraphQL/Types/StreamDataQueryDto.cs`
- Create: `octo-asset-repo-services/src/AssetRepositoryServices/GraphQL/Types/StreamDataQueryDtoType.cs`

- [ ] **Step 1: Create the descriptor DTO**

```csharp
using Meshmakers.Octo.Communication.Contracts.DataTransferObjects;
using Meshmakers.Octo.ConstructionKit.Contracts;
using Meshmakers.Octo.ConstructionKit.Models.System.Generated.System.v2;

namespace Meshmakers.Octo.Backend.AssetRepositoryServices.GraphQL.Types;

internal sealed class StreamDataQueryDto : GraphQlDto
{
    public required OctoObjectId QueryRtId { get; init; }
    public required RtCkId<CkTypeId> AssociatedCkTypeId { get; init; }
    public required IReadOnlyList<RtQueryColumn> Columns { get; init; }
    public required StreamDataQueryUserContext UserContext { get; init; }
}

internal sealed class StreamDataQueryUserContext
{
    public required RtStreamDataQuery LoadedQuery { get; init; }
}
```

- [ ] **Step 2: Create the GraphQL type (descriptor fields only — sub-connections in next tasks)**

```csharp
using GraphQL;
using GraphQL.Types;
using Meshmakers.Octo.Backend.AssetRepositoryServices.GraphQL.Types.Scalars;
using Meshmakers.Octo.Backend.AssetRepositoryServices.GraphQL.Utils;
using Meshmakers.Octo.ConstructionKit.Contracts;

namespace Meshmakers.Octo.Backend.AssetRepositoryServices.GraphQL.Types;

internal sealed class StreamDataQueryDtoType : ObjectGraphType<StreamDataQueryDto>
{
    public StreamDataQueryDtoType(ILogger<StreamDataQueryDtoType> logger)
    {
        Name = "StreamDataQueryDescriptor";
        Description = "Descriptor for a persisted stream-data query. Holds column metadata; .Rows and .Aggregations sub-connections execute the query.";
        Field(d => d.QueryRtId, typeof(NonNullGraphType<OctoObjectIdType>));
        Field(d => d.AssociatedCkTypeId, typeof(NonNullGraphType<RtCkIdGraph<CkTypeId>>));
        Field(d => d.Columns, typeof(NonNullGraphType<ListGraphType<NonNullGraphType<RtQueryColumnType>>>));

        // Sub-connections added in Tasks 4.2 (Rows) and 4.3 (Aggregations)
    }
}
```

- [ ] **Step 3: Build (expect no regressions; type isn't wired yet)**

```bash
dotnet build /Users/reimar/dev/meshmakers/branches/main/octo-asset-repo-services -c DebugL 2>&1 | tail -5
```

- [ ] **Step 4: Commit**

```bash
git -C /Users/reimar/dev/meshmakers/branches/main/octo-asset-repo-services add src/AssetRepositoryServices/GraphQL/Types/StreamDataQueryDto.cs src/AssetRepositoryServices/GraphQL/Types/StreamDataQueryDtoType.cs
git -C /Users/reimar/dev/meshmakers/branches/main/octo-asset-repo-services commit -m "Add StreamDataQueryDto descriptor and type

Mirrors RtQueryDto + RtQueryDtoType. Sub-connections (.Rows, .Aggregations)
are added in follow-up commits. Root field not yet wired.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

### Task 4.2: Add shared `ExecuteVariantAsync` executor helper

**Files:**
- Create: `octo-asset-repo-services/src/AssetRepositoryServices/GraphQL/StreamDataVariantExecutor.cs`

This helper encapsulates the Execute*Async dispatch logic, used by both persistent `.Rows` (Task 4.3) and transient `.Rows` (Task 4.6).

- [ ] **Step 1: Create the executor**

```csharp
using Meshmakers.Octo.ConstructionKit.Contracts;
using Meshmakers.Octo.ConstructionKit.Models.System.Generated.System.v2;
using Meshmakers.Octo.Runtime.Contracts.Repositories.Query;
using Meshmakers.Octo.Runtime.Contracts.StreamData;

namespace Meshmakers.Octo.Backend.AssetRepositoryServices.GraphQL;

internal enum StreamQueryVariant { Simple, Aggregation, GroupingAggregation, Downsampling }

internal sealed class StreamQueryExecutionInput
{
    public required StreamQueryVariant Variant { get; init; }
    public required RtCkId<CkTypeId> CkTypeId { get; init; }
    public IReadOnlyList<string>? ColumnPaths { get; init; }
    public IReadOnlyList<AggregationColumn>? AggregationColumns { get; init; }
    public IReadOnlyList<string>? GroupByColumnPaths { get; init; }
    public DateTime? From { get; init; }
    public DateTime? To { get; init; }
    public int? Limit { get; init; }
    public IReadOnlyList<SortOrderItem>? SortOrders { get; init; }
    public IReadOnlyList<FieldFilter>? FieldFilters { get; init; }
    public IReadOnlyList<OctoObjectId>? RtIds { get; init; }
    public int? Offset { get; init; }
    public int? PageSize { get; init; }
}

internal static class StreamDataVariantExecutor
{
    public static async Task<StreamDataQueryResult> ExecuteAsync(
        IStreamDataRepository repo, StreamQueryExecutionInput i)
    {
        return i.Variant switch
        {
            StreamQueryVariant.Simple => await repo.ExecuteQueryAsync(
                StreamDataQueryOptions.Create()
                    .WithCkTypeId(i.CkTypeId)
                    .WithColumns(i.ColumnPaths ?? Array.Empty<string>())
                    .WithRtIds(i.RtIds)
                    .WithTimeRange(i.From, i.To)
                    .WithLimit(i.Limit)
                    .WithSortOrders(i.SortOrders)
                    .WithFieldFilters(i.FieldFilters)
                    .WithPagination(i.Offset, i.PageSize)),

            StreamQueryVariant.Aggregation => await repo.ExecuteAggregationQueryAsync(
                StreamDataAggregationQueryOptions.Create()
                    .WithCkTypeId(i.CkTypeId)
                    .WithAggregationColumns(i.AggregationColumns ?? Array.Empty<AggregationColumn>())
                    .WithRtIds(i.RtIds)
                    .WithTimeRange(i.From, i.To)
                    .WithFieldFilters(i.FieldFilters)),

            StreamQueryVariant.GroupingAggregation => await repo.ExecuteGroupedAggregationQueryAsync(
                StreamDataGroupedAggregationQueryOptions.Create()
                    .WithCkTypeId(i.CkTypeId)
                    .WithGroupByColumns(i.GroupByColumnPaths ?? Array.Empty<string>())
                    .WithAggregationColumns(i.AggregationColumns ?? Array.Empty<AggregationColumn>())
                    .WithRtIds(i.RtIds)
                    .WithTimeRange(i.From, i.To)
                    .WithFieldFilters(i.FieldFilters)),

            StreamQueryVariant.Downsampling => await repo.ExecuteDownsamplingQueryAsync(
                StreamDataDownsamplingQueryOptions.Create()
                    .WithCkTypeId(i.CkTypeId)
                    .WithAggregationColumns(i.AggregationColumns ?? Array.Empty<AggregationColumn>())
                    .WithTimeRange(i.From!.Value, i.To!.Value)
                    .WithLimit(i.Limit!.Value)
                    .WithRtIds(i.RtIds)
                    .WithFieldFilters(i.FieldFilters)),

            _ => throw new ArgumentOutOfRangeException(nameof(i.Variant))
        };
    }
}
```

- [ ] **Step 2: Build**

```bash
dotnet build /Users/reimar/dev/meshmakers/branches/main/octo-asset-repo-services -c DebugL 2>&1 | tail -5
```

- [ ] **Step 3: Commit**

```bash
git -C /Users/reimar/dev/meshmakers/branches/main/octo-asset-repo-services add src/AssetRepositoryServices/GraphQL/StreamDataVariantExecutor.cs
git -C /Users/reimar/dev/meshmakers/branches/main/octo-asset-repo-services commit -m "Extract StreamDataVariantExecutor shared helper

Single place that dispatches a StreamQueryExecutionInput to the right
IStreamDataRepository.Execute*Async method. Will be used by both the
persistent descriptor's .Rows resolver and the transient descriptor's
.Rows resolver.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

### Task 4.3: Add `.Rows` sub-connection on `StreamDataQueryDtoType`

**Files:**
- Modify: `octo-asset-repo-services/src/AssetRepositoryServices/GraphQL/Types/StreamDataQueryDtoType.cs`

- [ ] **Step 1: Add the sub-connection with dispatcher**

Inside the constructor, after the `Field(...)` lines:

```csharp
Connection<NonNullGraphType<StreamDataQueryRowDtoType>>("Rows")
    .Argument<StreamDataArgumentsGraphType>(Statics.StreamDataArgument, "Override time filter and limit at execution time.")
    .Argument<ListGraphType<SortDtoType>>(Statics.SortOrderArg, "Sort order override for Simple variant")
    .ResolveAsync(ResolveRowsAsync);
```

Add resolver method on the class:

```csharp
private async Task<object?> ResolveRowsAsync(IResolveConnectionContext<StreamDataQueryDto> ctx)
{
    try
    {
        if (ctx.Source is not { } dto)
            throw AssetRepositoryException.SourceNotSet();

        var gql = (GraphQlUserContext)ctx.UserContext;
        var repo = gql.TenantContext.GetStreamDataRepository()
            ?? throw AssetRepositoryException.StreamDataNotAvailable();

        var loaded = dto.UserContext.LoadedQuery;
        var execOverride = ctx.GetArgument<StreamDataArguments?>(Statics.StreamDataArgument);
        ctx.TryGetArgument(Statics.SortOrderArg, out IEnumerable<SortDto>? sortDtos);

        var input = BuildInputFromLoadedQuery(loaded, execOverride, sortDtos?.ToList(), ctx);
        var result = await StreamDataVariantExecutor.ExecuteAsync(repo, input);

        var columnNames = dto.Columns.Select(c => c.AttributePath).ToList();
        var rows = result.Rows
            .Select(r => StreamDataQueryRowDto.FromStreamDataRow(r, columnNames))
            .ToList();
        var offset = ctx.GetOffset().GetValueOrDefault(0);
        return ConnectionUtils.ToOctoConnection(rows, ctx,
            rows.Count != 0 ? offset : 0, (int)result.TotalCount);
    }
    catch (Exception e) { return ctx.HandleException(e); }
}

private static StreamQueryExecutionInput BuildInputFromLoadedQuery(
    RtStreamDataQuery loaded, StreamDataArguments? execOverride,
    List<SortDto>? runtimeSorts, IResolveConnectionContext<StreamDataQueryDto> ctx)
{
    var ckTypeId = new RtCkId<CkTypeId>(loaded.QueryCkTypeId);
    var rtIds = loaded.RtIds?.Select(id => new OctoObjectId(id)).ToList();
    var from = execOverride?.From ?? loaded.From;
    var to = execOverride?.To ?? loaded.To;
    var limit = execOverride?.Limit ?? (loaded.Limit.HasValue ? (int)loaded.Limit.Value : (int?)null);
    var fieldFilters = StreamDataGraphQlMapper.MapCkFieldFilters(
        loaded.FieldFilter?.ToList(),
        f => f.AttributePath, f => f.Operator, f => f.ComparisonValue);

    return loaded switch
    {
        RtSimpleSdQuery s => new StreamQueryExecutionInput
        {
            Variant = StreamQueryVariant.Simple,
            CkTypeId = ckTypeId,
            ColumnPaths = s.Columns?.ToList() ?? [],
            RtIds = rtIds,
            From = from,
            To = to,
            Limit = limit,
            SortOrders = runtimeSorts is { Count: > 0 }
                ? StreamDataGraphQlMapper.MapSortOrders(runtimeSorts)
                : StreamDataGraphQlMapper.MapCkSortOrders(s.Sorting?.ToList(),
                    so => so.AttributePath, so => so.SortOrder),
            FieldFilters = fieldFilters,
            Offset = ctx.GetOffset(),
            PageSize = ctx.First
        },

        RtAggregationSdQuery a => new StreamQueryExecutionInput
        {
            Variant = StreamQueryVariant.Aggregation,
            CkTypeId = ckTypeId,
            AggregationColumns = a.Columns?.Select(c => new AggregationColumn(c.AttributePath, c.AggregationType)).ToList() ?? [],
            RtIds = rtIds,
            From = from,
            To = to,
            FieldFilters = fieldFilters
        },

        RtGroupingAggregationSdQuery g => new StreamQueryExecutionInput
        {
            Variant = StreamQueryVariant.GroupingAggregation,
            CkTypeId = ckTypeId,
            GroupByColumnPaths = g.GroupingColumns?.ToList() ?? [],
            AggregationColumns = g.Columns?.Select(c => new AggregationColumn(c.AttributePath, c.AggregationType)).ToList() ?? [],
            RtIds = rtIds,
            From = from,
            To = to,
            FieldFilters = fieldFilters
        },

        RtDownsamplingSdQuery d => new StreamQueryExecutionInput
        {
            Variant = StreamQueryVariant.Downsampling,
            CkTypeId = ckTypeId,
            AggregationColumns = d.Columns?.Select(c => new AggregationColumn(c.AttributePath, c.AggregationType)).ToList() ?? [],
            From = from ?? throw new InvalidOperationException("Downsampling requires From"),
            To = to ?? throw new InvalidOperationException("Downsampling requires To"),
            Limit = limit ?? throw new InvalidOperationException("Downsampling requires Limit"),
            RtIds = rtIds,
            FieldFilters = fieldFilters
        },

        _ => throw AssetRepositoryException.RtQueryTypeUnknown(loaded.GetType().Name)
    };
}
```

The per-subtype bodies mirror what the four current `ResolveStreamData{Variant}RtQueryAsync` resolvers in `StreamDataQuery.cs` do today; this consolidates them. `StreamDataGraphQlMapper.MapCkSortOrders` and `MapCkFieldFilters` already exist — they convert from CK record shapes (the `.Sorting`, `.FieldFilter` properties on loaded entities) to the shared `SortOrderItem` / `FieldFilter` types.

- [ ] **Step 2: Build**

```bash
dotnet build /Users/reimar/dev/meshmakers/branches/main/octo-asset-repo-services -c DebugL 2>&1 | tail -10
```

Expected: green.

- [ ] **Step 3: Commit**

```bash
git -C /Users/reimar/dev/meshmakers/branches/main/octo-asset-repo-services add src/AssetRepositoryServices/GraphQL/Types/StreamDataQueryDtoType.cs
git -C /Users/reimar/dev/meshmakers/branches/main/octo-asset-repo-services commit -m "Add .Rows sub-connection on StreamDataQueryDtoType

Dispatches on the loaded RtStreamDataQuery subtype via
StreamDataVariantExecutor. Not wired to a root field yet.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

### Task 4.4: Add `.Aggregations` sub-connection on `StreamDataQueryDtoType`

**Files:**
- Modify: `octo-asset-repo-services/src/AssetRepositoryServices/GraphQL/Types/StreamDataQueryDtoType.cs`

- [ ] **Step 1: Add the sub-connection**

```csharp
Connection<NonNullGraphType<QueryAggregationResultType>>("Aggregations")
    .Argument<NonNullGraphType<ResultAggregationInputDtoType>>(Statics.AggregationsArg,
        "Count/Min/Max/Avg/Sum statistics to compute across the matched row set.")
    .ResolveAsync(ResolveAggregationsAsync);
```

- [ ] **Step 2: Implement the resolver**

```csharp
private async Task<object?> ResolveAggregationsAsync(IResolveConnectionContext<StreamDataQueryDto> ctx)
{
    try
    {
        if (ctx.Source is not { } dto)
            throw AssetRepositoryException.SourceNotSet();

        var gql = (GraphQlUserContext)ctx.UserContext;
        var repo = gql.TenantContext.GetStreamDataRepository()
            ?? throw AssetRepositoryException.StreamDataNotAvailable();

        var aggInput = ctx.GetArgument<ResultAggregationInput>(Statics.AggregationsArg);

        // Build an AggregationSdQuery-shaped input from the loaded query's filter set + the requested stats.
        var loaded = dto.UserContext.LoadedQuery;
        var aggColumns = aggInput.ToAggregationColumns();  // helper that flattens count/min/max/avg/sum paths into List<AggregationColumn>

        var input = new StreamQueryExecutionInput
        {
            Variant = StreamQueryVariant.Aggregation,
            CkTypeId = dto.AssociatedCkTypeId,
            AggregationColumns = aggColumns,
            RtIds = loaded.RtIds?.Select(id => new OctoObjectId(id)).ToList(),
            From = loaded.From,
            To = loaded.To,
            FieldFilters = MapFieldFilters(loaded.FieldFilter)
        };

        var result = await StreamDataVariantExecutor.ExecuteAsync(repo, input);

        var stats = BuildQueryAggregationResult(aggInput, result);
        return ConnectionUtils.ToOctoConnection(new[] { stats }, ctx, 0, 1);
    }
    catch (Exception e) { return ctx.HandleException(e); }
}

private static QueryAggregationResult BuildQueryAggregationResult(
    ResultAggregationInput input, StreamDataQueryResult result)
{
    // Aggregation variant returns (typically) a single row whose Values dict contains columns
    // like "Count_Voltage", "Avg_Voltage", "Min_Voltage" per requested path + function.
    var row = result.Rows.FirstOrDefault();
    var values = row?.Values ?? new Dictionary<string, object?>();

    static IReadOnlyList<StatisticItem> Collect(IReadOnlyDictionary<string, object?> vals, string prefix, IEnumerable<string>? paths) =>
        (paths ?? Array.Empty<string>())
            .Select(p => new StatisticItem
            {
                AttributePath = p,
                Value = vals.TryGetValue($"{prefix}_{p}", out var v) ? v : null
            })
            .ToList();

    return new QueryAggregationResult(
        TotalCount: result.TotalCount,
        CountStatistics: Collect(values, "Count", input.Count?.AttributePaths),
        MinStatistics:   Collect(values, "Min",   input.Minimum?.AttributePaths),
        MaxStatistics:   Collect(values, "Max",   input.Maximum?.AttributePaths),
        AvgStatistics:   Collect(values, "Avg",   input.Average?.AttributePaths),
        SumStatistics:   Collect(values, "Sum",   input.Sum?.AttributePaths));
}
```

- [ ] **Step 3: Build**

```bash
dotnet build /Users/reimar/dev/meshmakers/branches/main/octo-asset-repo-services -c DebugL 2>&1 | tail -5
```

- [ ] **Step 4: Commit**

```bash
git -C /Users/reimar/dev/meshmakers/branches/main/octo-asset-repo-services add src/AssetRepositoryServices/GraphQL/Types/StreamDataQueryDtoType.cs
git -C /Users/reimar/dev/meshmakers/branches/main/octo-asset-repo-services commit -m "Add .Aggregations sub-connection on StreamDataQueryDtoType

Runs an Aggregation-variant query against the loaded query's filter set
with the requested stats and projects into the shared QueryAggregationResult
shape.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

### Task 4.5: Replace 4 persistent roots with single `StreamDataQuery(rtId)`

**Files:**
- Modify: `octo-asset-repo-services/src/AssetRepositoryServices/GraphQL/StreamDataQuery.cs`

- [ ] **Step 1: Delete the four top-level persistent connection registrations**

In the constructor, remove:
- `Connection<NonNullGraphType<StreamDataQueryRowDtoType>>("StreamDataQuery", …)` — old 4-variant
- `Connection<…>("StreamDataAggregationQuery", …)`
- `Connection<…>("StreamDataGroupingAggregationQuery", …)`
- `Connection<…>("StreamDataDownsamplingQuery", …)`

Replace with one:

```csharp
Connection<NonNullGraphType<StreamDataQueryDtoType>>("StreamDataQuery")
    .Argument<NonNullGraphType<OctoObjectIdType>>(Statics.RtIdArg, "The persisted stream-data query runtime id.")
    .ResolveAsync(ResolveStreamDataQueryAsync);
```

- [ ] **Step 2: Implement `ResolveStreamDataQueryAsync`**

```csharp
private async Task<object?> ResolveStreamDataQueryAsync(IResolveConnectionContext<object?> ctx)
{
    try
    {
        var sessionAccessor = ctx.GetSessionAccessor();
        var gql = (GraphQlUserContext)ctx.UserContext;
        var repo = gql.TenantContext.GetTenantRepository();

        var queryRtId = ctx.GetArgument<OctoObjectId>(Statics.RtIdArg);
        var loaded = await repo.GetRtEntityByRtIdAsync<RtStreamDataQuery>(sessionAccessor.Session, queryRtId)
            ?? throw AssetRepositoryException.RtQueryNotFound(queryRtId);

        // Build column metadata for the descriptor
        var columns = ExtractColumnsFromLoaded(loaded);

        var dto = new StreamDataQueryDto
        {
            QueryRtId = queryRtId,
            AssociatedCkTypeId = new RtCkId<CkTypeId>(loaded.QueryCkTypeId),
            Columns = columns,
            UserContext = new StreamDataQueryUserContext { LoadedQuery = loaded }
        };

        return ConnectionUtils.ToOctoConnection(new[] { dto }, ctx, 0, 1);
    }
    catch (Exception e) { return ctx.HandleException(e); }
}

private static IReadOnlyList<RtQueryColumn> ExtractColumnsFromLoaded(RtStreamDataQuery loaded) => loaded switch
{
    RtSimpleSdQuery s               => s.Columns.Select(p => new RtQueryColumn(p, null)).ToList(),
    RtAggregationSdQuery a          => a.Columns.Select(c => new RtQueryColumn(c.AttributePath, c.AggregationType)).ToList(),
    RtGroupingAggregationSdQuery g  => g.GroupingColumns.Select(p => new RtQueryColumn(p, null))
                                        .Concat(g.Columns.Select(c => new RtQueryColumn(c.AttributePath, c.AggregationType)))
                                        .ToList(),
    RtDownsamplingSdQuery d         => d.Columns.Select(c => new RtQueryColumn(c.AttributePath, c.AggregationType)).ToList(),
    _ => throw AssetRepositoryException.RtQueryTypeUnknown(loaded.GetType().Name)
};
```

- [ ] **Step 3: Delete the 4 old top-level resolvers**

Remove `ResolveStreamDataRtQueryAsync`, `ResolveStreamDataAggregationRtQueryAsync`, `ResolveStreamDataGroupingAggregationRtQueryAsync`, `ResolveStreamDataDownsamplingRtQueryAsync` — all the code is now inside `StreamDataQueryDtoType.BuildInputFromLoadedQuery`.

- [ ] **Step 4: Build**

```bash
dotnet build /Users/reimar/dev/meshmakers/branches/main/octo-asset-repo-services -c DebugL 2>&1 | tail -10
```

- [ ] **Step 5: Update existing persistent-query integration tests to the new GraphQL shape**

The tests that query `{ StreamData { StreamDataAggregationQuery(rtId: ...) { edges { node { cells { ... } } } } } }` become:

```graphql
{ StreamData { StreamDataQuery(rtId: ...) {
    edges { node {
        QueryRtId
        AssociatedCkTypeId
        Columns { attributePath aggregationType }
        Rows { edges { node { cells { attributePath, value } } } }
    } }
} } }
```

Update `AssetRepositoryServices.IntegrationTests/StreamData/StreamDataAggregationQueryTests.cs` and any persistent-query-specific test. Run the tests to confirm green.

- [ ] **Step 6: Commit**

```bash
git -C /Users/reimar/dev/meshmakers/branches/main/octo-asset-repo-services add src/AssetRepositoryServices/GraphQL/StreamDataQuery.cs tests/AssetRepositoryServices.IntegrationTests/
git -C /Users/reimar/dev/meshmakers/branches/main/octo-asset-repo-services commit -m "Collapse 4 stream persistent roots into one StreamDataQuery(rtId) with descriptor

Single root returns StreamDataQueryDto carrying column metadata + a
.Rows sub-connection (dispatches on loaded subtype) and an .Aggregations
sub-connection (computes stats via a second repository call).

Integration tests updated to new shape.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

### Task 4.6: Build transient namespace + descriptor

**Files:**
- Create: `octo-asset-repo-services/src/AssetRepositoryServices/GraphQL/StreamDataTransientQuery.cs`
- Create: `octo-asset-repo-services/src/AssetRepositoryServices/GraphQL/Types/StreamDataTransientQueryDto.cs`
- Create: `octo-asset-repo-services/src/AssetRepositoryServices/GraphQL/Types/StreamDataTransientQueryDtoType.cs`

- [ ] **Step 1: Create the transient descriptor DTO**

```csharp
internal sealed class StreamDataTransientQueryDto : GraphQlDto
{
    public required RtCkId<CkTypeId> QueryCkTypeId { get; init; }
    public required IReadOnlyList<RtQueryColumn> Columns { get; init; }
    public required StreamDataTransientUserContext UserContext { get; init; }
}

internal sealed class StreamDataTransientUserContext
{
    public required StreamQueryVariant Variant { get; init; }
    public required RtCkId<CkTypeId> CkTypeId { get; init; }
    public IReadOnlyList<string>? ColumnPaths { get; init; }
    public IReadOnlyList<AggregationColumn>? AggregationColumns { get; init; }
    public IReadOnlyList<string>? GroupByColumnPaths { get; init; }
    public StreamDataArguments? StreamDataArguments { get; init; }
    public int? Limit { get; init; }
    public DateTime? From { get; init; }
    public DateTime? To { get; init; }
    public IReadOnlyList<SortOrderItem>? SortOrders { get; init; }
    public IReadOnlyList<FieldFilter>? FieldFilters { get; init; }
    public IReadOnlyList<OctoObjectId>? RtIds { get; init; }
}
```

- [ ] **Step 2: Create the transient descriptor GraphQL type**

Same shape as `StreamDataQueryDtoType` but `.Rows` and `.Aggregations` read from `UserContext` (transient) rather than the loaded query. The executor input is built from `UserContext` fields directly. Reuse `StreamDataVariantExecutor.ExecuteAsync`.

- [ ] **Step 3: Create the `StreamDataTransientQuery` namespace type**

```csharp
public sealed class StreamDataTransientQuery : ObjectGraphType
{
    public StreamDataTransientQuery(ILogger<StreamDataTransientQuery> logger)
    {
        Name = "StreamDataTransient";
        Description = "Transient stream-data queries constructed ad-hoc at execution time.";

        Connection<NonNullGraphType<StreamDataTransientQueryDtoType>>("Simple")
            .Argument<NonNullGraphType<StringGraphType>>(Statics.CkIdArg, "CK type id")
            .Argument<NonNullGraphType<ListGraphType<NonNullGraphType<StringGraphType>>>>(Statics.ColumnPathsArg, "Attribute paths")
            .Argument<StreamDataArgumentsGraphType>(Statics.StreamDataArgument, "Time filter + limit")
            .Argument<ListGraphType<SortDtoType>>(Statics.SortOrderArg, "Sort order")
            .Argument<ListGraphType<FieldFilterDtoType>>(Statics.FieldFilterArg, "Field filters")
            .Argument<ListGraphType<OctoObjectIdType>>(Statics.RtIdsArg, "Scope to entity IDs")
            .ResolveAsync(ResolveSimpleAsync);

        Connection<NonNullGraphType<StreamDataTransientQueryDtoType>>("Aggregation")
            .Argument<NonNullGraphType<StringGraphType>>(Statics.CkIdArg, …)
            .Argument<NonNullGraphType<ListGraphType<NonNullGraphType<StreamDataQueryColumnInputDtoType>>>>(Statics.ColumnPathsArg, …)
            .Argument<StreamDataArgumentsGraphType>(Statics.StreamDataArgument, …)
            .Argument<ListGraphType<FieldFilterDtoType>>(Statics.FieldFilterArg, …)
            .Argument<ListGraphType<OctoObjectIdType>>(Statics.RtIdsArg, …)
            .ResolveAsync(ResolveAggregationAsync);

        Connection<NonNullGraphType<StreamDataTransientQueryDtoType>>("GroupingAggregation")
            .Argument<NonNullGraphType<StringGraphType>>(Statics.CkIdArg, …)
            .Argument<NonNullGraphType<ListGraphType<NonNullGraphType<StringGraphType>>>>(Statics.GroupByColumnPathsArg, …)
            .Argument<NonNullGraphType<ListGraphType<NonNullGraphType<StreamDataQueryColumnInputDtoType>>>>(Statics.ColumnPathsArg, …)
            .Argument<StreamDataArgumentsGraphType>(Statics.StreamDataArgument, …)
            .Argument<ListGraphType<FieldFilterDtoType>>(Statics.FieldFilterArg, …)
            .Argument<ListGraphType<OctoObjectIdType>>(Statics.RtIdsArg, …)
            .ResolveAsync(ResolveGroupingAggregationAsync);

        Connection<NonNullGraphType<StreamDataTransientQueryDtoType>>("Downsampling")
            .Argument<NonNullGraphType<StringGraphType>>(Statics.CkIdArg, …)
            .Argument<NonNullGraphType<ListGraphType<NonNullGraphType<StreamDataQueryColumnInputDtoType>>>>(Statics.ColumnPathsArg, …)
            .Argument<NonNullGraphType<IntGraphType>>("limit", "Bucket count")
            .Argument<NonNullGraphType<DateTimeGraphType>>("from", "Range start")
            .Argument<NonNullGraphType<DateTimeGraphType>>("to", "Range end")
            .Argument<ListGraphType<FieldFilterDtoType>>(Statics.FieldFilterArg, …)
            .Argument<ListGraphType<OctoObjectIdType>>(Statics.RtIdsArg, …)
            .ResolveAsync(ResolveDownsamplingAsync);
    }

    private async Task<object?> ResolveSimpleAsync(IResolveConnectionContext<object?> ctx)
    {
        try
        {
            var gql = (GraphQlUserContext)ctx.UserContext;
            var ckTypeId = ctx.GetArgument<RtCkId<CkTypeId>>(Statics.CkIdArg);
            var columnPaths = ctx.GetArgument<IEnumerable<string>>(Statics.ColumnPathsArg).ToList();

            var fieldResolver = BuildFieldResolver(ctx, gql.TenantId, ckTypeId);
            ctx.TryGetArgument(Statics.SortOrderArg, out IEnumerable<SortDto>? sortDtos);
            ctx.TryGetArgument(Statics.FieldFilterArg, out IEnumerable<FieldFilterDto>? fieldFilterDtos);
            ctx.TryGetArgument(Statics.RtIdsArg, null, out IEnumerable<OctoObjectId>? rtIds);
            var execArgs = ctx.GetArgument<StreamDataArguments?>(Statics.StreamDataArgument);
            var fieldFilters = fieldFilterDtos?.ToList();

            StreamDataFieldValidation.ValidateStreamDataFields(
                fieldResolver, columnPaths,
                sortDtos?.Select(s => s.AttributePath),
                fieldFilters?.Where(f => f.ComparisonValue != null).Select(f => f.AttributePath));

            var columns = columnPaths
                .Select(p => new RtQueryColumn(p, null))
                .ToList();

            var dto = new StreamDataTransientQueryDto
            {
                QueryCkTypeId = ckTypeId,
                Columns = columns,
                UserContext = new StreamDataTransientUserContext
                {
                    Variant = StreamQueryVariant.Simple,
                    CkTypeId = ckTypeId,
                    ColumnPaths = columnPaths,
                    StreamDataArguments = execArgs,
                    SortOrders = StreamDataGraphQlMapper.MapSortOrders(sortDtos),
                    FieldFilters = StreamDataGraphQlMapper.MapFieldFilters(fieldFilters),
                    RtIds = rtIds?.ToList()
                }
            };

            return ConnectionUtils.ToOctoConnection(new[] { dto }, ctx, 0, 1);
        }
        catch (Exception e) { return ctx.HandleException(e); }
    }

    // ResolveAggregationAsync, ResolveGroupingAggregationAsync, ResolveDownsamplingAsync follow
    // the same shape: read different args, set Variant to the matching value, populate
    // AggregationColumns / GroupByColumnPaths / Limit / From / To as appropriate.
}
```

Each of the four resolvers is ~30-40 LoC — arg reading + validation + DTO construction. No DB call.

- [ ] **Step 4: Replace 4 flat transient roots in `StreamDataQuery.cs`**

Delete the four top-level `Connection<...>("TransientStreamData*", …)` registrations. Replace with:

```csharp
Field<NonNullGraphType<StreamDataTransientQuery>>("TransientStreamDataQuery")
    .Description("Transient stream-data queries")
    .Resolve(_ => new { });
```

Delete the four old resolvers (`ResolveTransientStreamDataQueryAsync`, `ResolveTransientStreamDataAggregationQueryAsync`, `ResolveTransientStreamDataGroupedAggregationQueryAsync`, `ResolveTransientStreamDataDownsamplingQueryAsync`) from `StreamDataQuery.cs`.

- [ ] **Step 5: Build**

```bash
dotnet build /Users/reimar/dev/meshmakers/branches/main/octo-asset-repo-services -c DebugL 2>&1 | tail -10
```

- [ ] **Step 6: Update transient-query integration tests**

Same GraphQL shape change as Task 4.5 step 5 but nested under `TransientStreamDataQuery.{Simple,Aggregation,GroupingAggregation,Downsampling}`. Update and run.

- [ ] **Step 7: Commit**

```bash
git -C /Users/reimar/dev/meshmakers/branches/main/octo-asset-repo-services add -A src/AssetRepositoryServices/GraphQL/ tests/
git -C /Users/reimar/dev/meshmakers/branches/main/octo-asset-repo-services commit -m "Collapse 4 transient stream roots into TransientStreamDataQuery namespace

Mirrors RT's TransientQuery.{Simple,Aggregation,GroupingAggregation} with
the addition of Downsampling. Each sub-connection returns a
StreamDataTransientQueryDto descriptor with .Rows and .Aggregations
sub-connections backed by the same StreamDataVariantExecutor used by
the persistent path.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

### Task 4.7: Integration test for `.Aggregations` on both persistent and transient

**Files:**
- Create: `octo-asset-repo-services/tests/AssetRepositoryServices.IntegrationTests/StreamData/StreamDataAggregationsSubConnectionTests.cs`

- [ ] **Step 1: Test transient `.Aggregations`**

```csharp
[Fact]
public async Task TransientStreamDataQuery_Simple_WithAggregations_ReturnsStats()
{
    const string query = """
        query {
            StreamData {
                TransientStreamDataQuery {
                    Simple(ckId: "AssetRepositoryIntegrationTest/MeteringPoint"
                           columnPaths: ["Voltage"]
                           streamDataArguments: { from: "2026-01-01T10:00:00Z", to: "2026-01-01T10:15:00Z" }) {
                        edges { node {
                            Aggregations(aggregations: { average: { attributePaths: ["Voltage"] } }) {
                                edges { node { avgStatistics { attributePath, value } } }
                            }
                        } }
                    }
                }
            }
        }
    """;
    var result = await fixture.ExecuteGraphQlAsync(query);
    Assert.Null(result.Errors);
    Assert.Contains("avgStatistics", fixture.SerializeGraphQl(result));
}
```

- [ ] **Step 2: Run**

```bash
dotnet test /Users/reimar/dev/meshmakers/branches/main/octo-asset-repo-services/tests/AssetRepositoryServices.IntegrationTests -c DebugL --filter "FullyQualifiedName~Aggregations" 2>&1 | tail -5
```

Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git -C /Users/reimar/dev/meshmakers/branches/main/octo-asset-repo-services add tests/AssetRepositoryServices.IntegrationTests/StreamData/StreamDataAggregationsSubConnectionTests.cs
git -C /Users/reimar/dev/meshmakers/branches/main/octo-asset-repo-services commit -m "Integration test for stream .Aggregations sub-connection

Covers the transient Simple → Aggregations flow.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

---

## Phase 5 — Per-type migration + generic endpoint

### Task 5.1: Add generic `StreamDataEntityGenericDtoType`

**Files:**
- Create: `octo-asset-repo-services/src/AssetRepositoryServices/GraphQL/Types/StreamDataEntityGenericDtoType.cs`

- [ ] **Step 1: Create the cells-based type**

Pattern-match on `RtEntityGenericDtoType`; the stream version wraps `StreamDataQueryRowDto` as the underlying row (already cells-based with `cells: [{attributePath, value}]`).

```csharp
internal sealed class StreamDataEntityGenericDtoType : ObjectGraphType<StreamDataQueryRowDto>
{
    public StreamDataEntityGenericDtoType()
    {
        Name = "StreamDataEntityGeneric";
        Description = "Generic cells-based stream-data row when the CkType is supplied at query time.";
        Field(d => d.RtId, typeof(OctoObjectIdType));
        Field(d => d.CkTypeId, typeof(RtCkIdGraph<CkTypeId>));
        Field(d => d.Timestamp, typeof(DateTimeGraphType));
        Field(d => d.RtWellKnownName, nullable: true);
        Field(d => d.RtCreationDateTime, typeof(DateTimeGraphType));
        Field(d => d.RtChangedDateTime, typeof(DateTimeGraphType));

        Connection<NonNullGraphType<RtQueryCellDtoType>>("Cells")
            .Description("Selected attribute cells for this row.")
            .Resolve(ResolveCells);
    }

    private static object ResolveCells(IResolveConnectionContext<StreamDataQueryRowDto> ctx)
    {
        var row = ctx.Source;
        var cells = row.ColumnNames.Select(name =>
        {
            row.Values.TryGetValue(name, out var v);
            return new RtQueryCellDto { AttributePath = name, Value = v };
        });
        return ConnectionUtils.ToOctoConnection(cells, ctx);
    }
}
```

- [ ] **Step 2: Build, commit**

```bash
dotnet build /Users/reimar/dev/meshmakers/branches/main/octo-asset-repo-services -c DebugL 2>&1 | tail -3
git -C /Users/reimar/dev/meshmakers/branches/main/octo-asset-repo-services add src/AssetRepositoryServices/GraphQL/Types/StreamDataEntityGenericDtoType.cs
git -C /Users/reimar/dev/meshmakers/branches/main/octo-asset-repo-services commit -m "Add StreamDataEntityGenericDtoType for generic cells-based endpoint" 
```

### Task 5.2: Add `StreamDataEntities(ckId)` root connection

**Files:**
- Modify: `octo-asset-repo-services/src/AssetRepositoryServices/GraphQL/StreamDataQuery.cs`

- [ ] **Step 1: Register the connection in the constructor**

```csharp
Connection<NonNullGraphType<StreamDataEntityGenericDtoType>>("StreamDataEntities")
    .Argument<NonNullGraphType<StringGraphType>>(Statics.CkIdArg, "CK type id")
    .Argument<NonNullGraphType<ListGraphType<NonNullGraphType<StringGraphType>>>>(Statics.ColumnPathsArg, "Attribute paths to project")
    .Argument<StreamDataArgumentsGraphType>(Statics.StreamDataArgument, "Time filter + limit")
    .Argument<ListGraphType<SortDtoType>>(Statics.SortOrderArg, "Sort order")
    .Argument<ListGraphType<FieldFilterDtoType>>(Statics.FieldFilterArg, "Field filters")
    .Argument<ListGraphType<OctoObjectIdType>>(Statics.RtIdsArg, "Scope to entity IDs")
    .ResolveAsync(ResolveStreamDataEntitiesAsync);
```

- [ ] **Step 2: Implement resolver**

```csharp
private async Task<object?> ResolveStreamDataEntitiesAsync(IResolveConnectionContext<object?> ctx)
{
    try
    {
        var gql = (GraphQlUserContext)ctx.UserContext;
        var repo = gql.TenantContext.GetStreamDataRepository()
            ?? throw AssetRepositoryException.StreamDataNotAvailable();

        var ckTypeId = ctx.GetArgument<RtCkId<CkTypeId>>(Statics.CkIdArg);
        var columnPaths = ctx.GetArgument<IEnumerable<string>>(Statics.ColumnPathsArg).ToList();

        var fieldResolver = BuildFieldResolver(ctx, gql.TenantId, ckTypeId);
        ctx.TryGetArgument(Statics.SortOrderArg, out IEnumerable<SortDto>? sortDtos);
        ctx.TryGetArgument(Statics.FieldFilterArg, out IEnumerable<FieldFilterDto>? fieldFilterDtos);
        ctx.TryGetArgument(Statics.RtIdsArg, null, out IEnumerable<OctoObjectId>? rtIds);
        var execArgs = ctx.GetArgument<StreamDataArguments?>(Statics.StreamDataArgument);

        StreamDataFieldValidation.ValidateStreamDataFields(
            fieldResolver, columnPaths,
            sortDtos?.Select(s => s.AttributePath),
            fieldFilterDtos?.Where(f => f.ComparisonValue != null).Select(f => f.AttributePath));

        var resolvedColumnNames = columnPaths.Select(c => fieldResolver.Resolve(c)!.GraphQlAlias).ToList();

        var options = StreamDataQueryOptions.Create()
            .WithCkTypeId(ckTypeId)
            .WithColumns(columnPaths)
            .WithRtIds(rtIds?.ToList())
            .WithTimeRange(execArgs?.From, execArgs?.To)
            .WithLimit(execArgs?.Limit)
            .WithSortOrders(StreamDataGraphQlMapper.MapSortOrders(sortDtos))
            .WithFieldFilters(StreamDataGraphQlMapper.MapFieldFilters(fieldFilterDtos))
            .WithPagination(ctx.GetOffset(), ctx.First);

        var result = await repo.ExecuteQueryAsync(options);
        var rows = result.Rows.Select(r => StreamDataQueryRowDto.FromStreamDataRow(r, resolvedColumnNames)).ToList();
        var offset = ctx.GetOffset().GetValueOrDefault(0);
        return ConnectionUtils.ToOctoConnection(rows, ctx,
            rows.Count != 0 ? offset : 0, (int)result.TotalCount);
    }
    catch (Exception e) { return ctx.HandleException(e); }
}
```

- [ ] **Step 3: Build + integration test**

Add a minimal integration test that calls `{ StreamData { StreamDataEntities(ckId: ..., columnPaths: [...]) { edges { node { cells { attributePath, value } } } } } }` and asserts the result shape.

- [ ] **Step 4: Commit**

```bash
git -C /Users/reimar/dev/meshmakers/branches/main/octo-asset-repo-services add src/AssetRepositoryServices/GraphQL/StreamDataQuery.cs tests/AssetRepositoryServices.IntegrationTests/
git -C /Users/reimar/dev/meshmakers/branches/main/octo-asset-repo-services commit -m "Add generic StreamDataEntities(ckId) cells-based endpoint

Mirrors RT's RuntimeEntities(ckId). Routes through StreamDataQueryOptions +
IStreamDataRepository.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

### Task 5.3: Rewrite per-type connection to use typed `Sd{CkType}` rows

**Files:**
- Modify: `octo-asset-repo-services/src/AssetRepositoryServices/GraphQL/StreamDataQuery.cs`
- Modify: `octo-asset-repo-services/src/AssetRepositoryServices/GraphQL/Caches/GraphTypesCache.cs` (or wherever `GetStreamTypes` lives) — switch the returned metadata from cells-based `StreamDataEntityDtoType` to typed `Sd{CkType}DtoType`.

- [ ] **Step 1: Update `GetStreamTypes()` metadata source**

Switch from emitting one `StreamDataEntityDtoType` per CK type to one generated `Sd{CkType}DtoType` per CK type with `isDataStream` attributes. The source-generator output from Phase 3 should be discoverable the same way as `Rt{CkType}DtoType` — copy whatever pattern `GetTypes()` uses to enumerate runtime DTO types, filter by the `isDataStream` condition.

- [ ] **Step 2: Replace the per-type loop and resolver**

In `StreamDataQuery.cs` constructor, replace the existing `foreach (var rtEntityDtoType in graphTypesCache.GetStreamTypes())` body with:

```csharp
foreach (var sdEntityDtoType in graphTypesCache.GetStreamTypes())
{
    this.Connection<object?, IGraphType, SdEntity>(graphTypesCache, sdEntityDtoType, sdEntityDtoType.Name)
        .AddMetadata(Statics.CkId, sdEntityDtoType.CkTypeId.ToRtCkId())
        .AddMetadata("SdEntityType", sdEntityDtoType.SdEntityClrType)  // carry the typed Sd{CkType} System.Type
        .Argument<OctoObjectIdType>(Statics.RtIdArg, "Returns entity with given rtId.")
        .Argument<ListGraphType<OctoObjectIdType>>(Statics.RtIdsArg, "Returns entities with given rtIds.")
        .Argument<StreamDataArgumentsGraphType>(Statics.StreamDataArgument, "Stream data filter.")
        .Argument<ListGraphType<SortDtoType>>(Statics.SortOrderArg, "Sort order.")
        .Argument<ListGraphType<FieldFilterDtoType>>(Statics.FieldFilterArg, "Field filters.")
        .ResolveAsync(ResolveStreamDataEntitiesByTypeAsync);
}
```

Replace the resolver body entirely (delete the old `~200 LoC` block that uses `CrateQueryBuilder`):

```csharp
private async Task<object?> ResolveStreamDataEntitiesByTypeAsync(IResolveConnectionContext<object?> ctx)
{
    try
    {
        var fieldContext = FieldContext.FromContext(ctx);
        var gql = (GraphQlUserContext)ctx.UserContext;
        var repo = gql.TenantContext.GetStreamDataRepository()
            ?? throw AssetRepositoryException.StreamDataNotAvailable();

        var ckTypeId = ctx.GetMetadataValue<RtCkId<CkTypeId>>(Statics.CkId);
        var sdEntityType = ctx.GetMetadataValue<Type>("SdEntityType");

        var fieldResolver = BuildFieldResolver(ctx, gql.TenantId, ckTypeId);
        var requestedType = ctx.GetCkCacheService().GetRtCkType(gql.TenantId, ckTypeId);
        var columnPaths = DeriveColumnPathsFromSelection(fieldContext, requestedType);

        ctx.TryGetArgument(Statics.SortOrderArg, out IEnumerable<SortDto>? sortDtos);
        ctx.TryGetArgument(Statics.FieldFilterArg, out IEnumerable<FieldFilterDto>? fieldFilterDtos);
        ctx.TryGetArgument(Statics.RtIdArg, out OctoObjectId? rtId);
        ctx.TryGetArgument(Statics.RtIdsArg, null, out IEnumerable<OctoObjectId>? rtIds);
        var execArgs = ctx.GetArgument<StreamDataArguments?>(Statics.StreamDataArgument);

        var rtIdList = new List<OctoObjectId>();
        if (rtId.HasValue) rtIdList.Add(rtId.Value);
        if (rtIds != null) rtIdList.AddRange(rtIds);
        if (rtIdList.Count == 0 && (ctx.HasArgument(Statics.RtIdArg) || ctx.HasArgument(Statics.RtIdsArg)))
            return ConnectionUtils.ToOctoConnection(Array.Empty<SdEntity>(), ctx);

        var options = StreamDataQueryOptions.Create()
            .WithCkTypeId(ckTypeId)
            .WithColumns(columnPaths)
            .WithRtIds(rtIdList.Count > 0 ? rtIdList : null)
            .WithTimeRange(execArgs?.From, execArgs?.To)
            .WithLimit(execArgs?.Limit)
            .WithSortOrders(StreamDataGraphQlMapper.MapSortOrders(sortDtos))
            .WithFieldFilters(StreamDataGraphQlMapper.MapFieldFilters(fieldFilterDtos))
            .WithPagination(ctx.GetOffset(), ctx.First);

        var result = await repo.ExecuteQueryAsync(options);

        // Hydrate via reflection on the Sd{CkType} type carried in metadata.
        var hydrateMethod = typeof(SdEntityHydrator).GetMethod("Hydrate")!.MakeGenericMethod(sdEntityType);
        var typedRows = result.Rows
            .Select(r => hydrateMethod.Invoke(null, new object[] { r })!)
            .Cast<SdEntity>()
            .ToList();

        var offset = ctx.GetOffset().GetValueOrDefault(0);
        return ConnectionUtils.ToOctoConnection(typedRows, ctx,
            typedRows.Count != 0 ? offset : 0, (int)result.TotalCount);
    }
    catch (Exception e) { return ctx.HandleException(e); }
}
```

- [ ] **Step 3: Add the `DeriveColumnPathsFromSelection` helper**

```csharp
private static IReadOnlyList<string> DeriveColumnPathsFromSelection(
    FieldContext fieldContext, CkTypeGraph requestedType)
{
    var itemField = fieldContext.Fields.FirstOrDefault(x => x.Name == Statics.ItemsQueryArg);
    if (itemField == null) return Array.Empty<string>();

    var dataStreamAttrs = requestedType.AllAttributes.Where(x => x.Value.IsDataStream).ToList();
    var result = new List<string>();
    foreach (var field in itemField.Fields)
    {
        var matchingAttr = dataStreamAttrs.FirstOrDefault(kvp =>
            string.Equals(kvp.Value.AttributeName, field.Name, StringComparison.InvariantCultureIgnoreCase));
        if (matchingAttr.Value != null)
            result.Add(matchingAttr.Value.AttributeName);
    }
    return result;
}
```

- [ ] **Step 4: Delete `HandleRequestedAttributes`, `HandleRequestedRtIds`, `AddVariable`, `ExecutePaginatedStreamDataQueryAsync`**

These helpers are no longer used. Grep to confirm no remaining callers, then delete from `StreamDataQuery.cs`.

```bash
grep -n "HandleRequestedAttributes\|HandleRequestedRtIds\|AddVariable\|ExecutePaginatedStreamDataQueryAsync" /Users/reimar/dev/meshmakers/branches/main/octo-asset-repo-services/src/AssetRepositoryServices/GraphQL/StreamDataQuery.cs
```

Expected: only the method-definition line hits (about to be deleted). No callers.

- [ ] **Step 5: Build and test**

```bash
dotnet build /Users/reimar/dev/meshmakers/branches/main/octo-asset-repo-services -c DebugL 2>&1 | tail -5
```

Add/update integration test that queries a per-type stream connection and asserts typed fields appear (e.g., `voltage`, `current`) rather than the old cells structure.

- [ ] **Step 6: Confirm no `CrateQueryBuilder` reference remains in asset-repo**

```bash
grep -rn "CrateQueryBuilder\|CrateQueryCompiler" /Users/reimar/dev/meshmakers/branches/main/octo-asset-repo-services/src --include="*.cs" 2>/dev/null | grep -v "/obj/" | grep -v "/bin/"
```

Expected: zero hits.

- [ ] **Step 7: Commit**

```bash
git -C /Users/reimar/dev/meshmakers/branches/main/octo-asset-repo-services add src/AssetRepositoryServices/GraphQL/ tests/
git -C /Users/reimar/dev/meshmakers/branches/main/octo-asset-repo-services commit -m "Migrate per-type stream connection to typed Sd{CkType} via options + hydrator

Per-type resolver now funnels through StreamDataQueryOptions and
IStreamDataRepository.ExecuteQueryAsync, hydrating rows into typed
Sd{CkType} instances via SdEntityHydrator. Dynamic field introspection
preserved via DeriveColumnPathsFromSelection helper. Four legacy helpers
deleted. No CrateQueryBuilder reference remains in asset-repo.

StreamDataQuery.cs is now ~250 LoC (down from 958).

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

---

## Phase 6 — Engine internals cleanup

### Task 6.1: Make `CrateQueryBuilder`/`Compiler`/`Exception` internal

**Files:**
- Modify: `octo-construction-kit-engine-mongodb/src/Runtime.Engine.MongoDb/StreamData/QueryBuilder/CrateQueryBuilder.cs`
- Modify: `octo-construction-kit-engine-mongodb/src/Runtime.Engine.MongoDb/StreamData/QueryBuilder/CrateQueryCompiler.cs`
- Modify: `octo-construction-kit-engine-mongodb/src/Runtime.Engine.MongoDb/StreamData/QueryBuilder/QueryBuilderException.cs`
- Modify: `octo-construction-kit-engine-mongodb/src/Runtime.Engine.MongoDb/Runtime.Engine.MongoDb.csproj` (add InternalsVisibleTo)

- [ ] **Step 1: Add InternalsVisibleTo to csproj**

In `Runtime.Engine.MongoDb.csproj`, add:

```xml
<ItemGroup>
    <InternalsVisibleTo Include="Meshmakers.Octo.Runtime.Engine.MongoDb.StreamData.UnitTests" />
</ItemGroup>
```

- [ ] **Step 2: Change visibility**

```bash
sed -i '' 's/^public class CrateQueryBuilder/internal class CrateQueryBuilder/' /Users/reimar/dev/meshmakers/branches/main/octo-construction-kit-engine-mongodb/src/Runtime.Engine.MongoDb/StreamData/QueryBuilder/CrateQueryBuilder.cs
sed -i '' 's/^public class CrateQueryCompiler/internal class CrateQueryCompiler/' /Users/reimar/dev/meshmakers/branches/main/octo-construction-kit-engine-mongodb/src/Runtime.Engine.MongoDb/StreamData/QueryBuilder/CrateQueryCompiler.cs
sed -i '' 's/^public class QueryBuilderException/internal class QueryBuilderException/' /Users/reimar/dev/meshmakers/branches/main/octo-construction-kit-engine-mongodb/src/Runtime.Engine.MongoDb/StreamData/QueryBuilder/QueryBuilderException.cs
```

- [ ] **Step 3: Build + test**

```bash
dotnet build /Users/reimar/dev/meshmakers/branches/main/octo-construction-kit-engine-mongodb -c DebugL 2>&1 | tail -5
dotnet test /Users/reimar/dev/meshmakers/branches/main/octo-construction-kit-engine-mongodb/tests/StreamData.UnitTests -c DebugL --no-build 2>&1 | tail -3
dotnet build /Users/reimar/dev/meshmakers/branches/main/octo-asset-repo-services -c DebugL 2>&1 | tail -5
```

Expected: all green. The InternalsVisibleTo keeps the unit tests compiling; asset-repo must also still compile (confirming Phase 5 fully removed external consumption).

- [ ] **Step 4: Commit**

```bash
git -C /Users/reimar/dev/meshmakers/branches/main/octo-construction-kit-engine-mongodb add src/Runtime.Engine.MongoDb/
git -C /Users/reimar/dev/meshmakers/branches/main/octo-construction-kit-engine-mongodb commit -m "Make CrateQueryBuilder/Compiler/Exception internal

All consumers now go through IStreamDataRepository. InternalsVisibleTo
for the StreamData unit tests keeps the existing test suite compiling.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

### Task 6.2: Delete `QueryModeDto` if unused

**Files:**
- Delete (maybe): `octo-construction-kit-engine-mongodb/src/Runtime.Engine.MongoDb/StreamData/Dtos/QueryModeDto.cs`

- [ ] **Step 1: Grep for callers**

```bash
grep -rn "QueryModeDto\|QueryMode\b" /Users/reimar/dev/meshmakers/branches/main --include="*.cs" 2>/dev/null | grep -v "/obj/" | grep -v "/bin/"
```

- [ ] **Step 2: If zero hits outside the file itself, delete**

```bash
rm /Users/reimar/dev/meshmakers/branches/main/octo-construction-kit-engine-mongodb/src/Runtime.Engine.MongoDb/StreamData/Dtos/QueryModeDto.cs
dotnet build /Users/reimar/dev/meshmakers/branches/main/octo-construction-kit-engine-mongodb -c DebugL 2>&1 | tail -3
```

If hits remain, skip this step and leave the type in place.

- [ ] **Step 3: Commit**

```bash
git -C /Users/reimar/dev/meshmakers/branches/main/octo-construction-kit-engine-mongodb add -A src/Runtime.Engine.MongoDb/StreamData/Dtos/
git -C /Users/reimar/dev/meshmakers/branches/main/octo-construction-kit-engine-mongodb commit -m "Delete unused QueryModeDto

No longer needed after the GraphQL-layer descriptor dispatcher replaced
the per-resolver mode branching.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

### Task 6.3: Audit and prune dead `CrateQueryBuilder` methods

**Files:**
- Modify: `octo-construction-kit-engine-mongodb/src/Runtime.Engine.MongoDb/StreamData/QueryBuilder/CrateQueryBuilder.cs`

- [ ] **Step 1: For each public method on `CrateQueryBuilder`, grep for internal consumers**

```bash
for method in AddFieldFilter AddVariable AddAggregationVariable IncludeDefaultVariables WithTimeFilter WithCkTypeIdFilter WithDownsampling WithLimit WithOffset OrderBy AddOrderByTiebreaker AddWhereIn; do
  echo "=== $method ==="
  grep -rn "$method" /Users/reimar/dev/meshmakers/branches/main/octo-construction-kit-engine-mongodb/src --include="*.cs" 2>/dev/null | grep -v "/obj/" | grep -v "/bin/" | grep -v "QueryBuilder/CrateQueryBuilder.cs" | head -3
done
```

- [ ] **Step 2: Remove any method with zero callers outside `CrateQueryBuilder.cs` itself**

For each orphan, delete the method + any private fields/helpers it uniquely depends on. Also delete the corresponding `CrateQueryBuilderTests` test cases since they're testing dead code — match the pruning.

- [ ] **Step 3: Build + test**

```bash
dotnet test /Users/reimar/dev/meshmakers/branches/main/octo-construction-kit-engine-mongodb/tests/StreamData.UnitTests -c DebugL 2>&1 | tail -3
```

Expected: all remaining tests green.

- [ ] **Step 4: Commit**

```bash
git -C /Users/reimar/dev/meshmakers/branches/main/octo-construction-kit-engine-mongodb add src/Runtime.Engine.MongoDb/StreamData/QueryBuilder/ tests/StreamData.UnitTests/
git -C /Users/reimar/dev/meshmakers/branches/main/octo-construction-kit-engine-mongodb commit -m "Prune dead CrateQueryBuilder methods after GraphQL migration

Removes public APIs only called by the deleted GraphQL-layer helpers.
Internal consumers (CrateDbStreamDataRepository) are unaffected.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

---

## Phase 7 — Frontend migration

> **⚠️ First schema regeneration requires the user.** The Apollo codegen step (`npm run codegen` in `octo-frontend-refinery-studio`) introspects the running backend's GraphQL schema. The FIRST run needs the new backend (Phases 1–6 merged, built, and running locally) plus any necessary auth setup — the user triggers this first run to confirm those preconditions.
>
> **Subsequent codegens the agent can run itself** — once the running backend is confirmed healthy by the user's first codegen, later `npm run codegen` invocations pick up the same endpoint and work without user intervention.
>
> **Protocol:** The first task that requires a `npm run codegen` — ASK THE USER to run it, wait for confirmation. Every codegen after that — agent runs `npm run codegen` directly in the working directory.

### Task 7.1: Update persistent query GraphQL ops

**Files:**
- Modify: Apollo `.graphql` files in `octo-frontend-refinery-studio/src/octo-mesh-refinery-studio/src/app/**/*.graphql` that reference `StreamDataQuery`, `StreamDataAggregationQuery`, `StreamDataGroupingAggregationQuery`, `StreamDataDownsamplingQuery` root fields.

- [ ] **Step 1: Find the persistent-query ops**

```bash
grep -rln "StreamDataQuery\|StreamDataAggregationQuery\|StreamDataGroupingAggregationQuery\|StreamDataDownsamplingQuery" /Users/reimar/dev/meshmakers/branches/main/octo-frontend-refinery-studio --include="*.graphql"
```

- [ ] **Step 2: Consolidate the 4 persistent-query ops into 1**

Before (4 separate files): `executeStreamDataQuery.graphql`, `executeStreamDataAggregationQuery.graphql`, etc.

After (1 file): `executeStreamDataQuery.graphql`:

```graphql
query executeStreamDataQuery($tenantId: TenantId!, $rtId: OctoObjectId!, $streamDataArguments: StreamDataArgumentsInput, $sortOrder: [SortInput!]) {
    tenant(tenantId: $tenantId) {
        streamData {
            streamDataQuery(rtId: $rtId) {
                edges {
                    node {
                        queryRtId
                        associatedCkTypeId
                        columns { attributePath, aggregationType }
                        rows(streamDataArguments: $streamDataArguments, sortOrder: $sortOrder) {
                            edges { node { cells { attributePath, value } } }
                            pageInfo { hasNextPage, endCursor }
                        }
                    }
                }
            }
        }
    }
}
```

Delete the three variant-specific persistent-query `.graphql` files.

- [ ] **Step 3: ASK THE USER to run codegen (FIRST codegen only)**

**This is the FIRST codegen in Phase 7 — the user triggers it to confirm the backend is running and auth is set up.**

Stop and prompt: "I've updated the persistent-query `.graphql` files. Please run `npm run codegen` in `octo-frontend-refinery-studio/src/octo-mesh-refinery-studio` and commit the regenerated `globalTypes.ts` + per-operation types. Let me know when it's done so I can continue."

Expected after user completes: `globalTypes.ts` and generated operation types rebuilt without the 3 deleted ops; user confirms.

**After this first run, subsequent codegens in later tasks (7.2, etc.) the agent runs directly.**

- [ ] **Step 4: Commit**

```bash
git -C /Users/reimar/dev/meshmakers/branches/main/octo-frontend-refinery-studio add -A src/ 
git -C /Users/reimar/dev/meshmakers/branches/main/octo-frontend-refinery-studio commit -m "Collapse 4 persistent stream-query GraphQL ops into 1

Matches the new descriptor-based GraphQL surface. Generated Apollo types
rebuilt.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

### Task 7.2: Update transient query GraphQL ops

**Files:**
- Modify: transient `.graphql` files.

- [ ] **Step 1: Consolidate 4 transient ops into 1 namespaced op**

```graphql
query executeTransientStreamDataQuery(
    $tenantId: TenantId!
    $variant: StreamDataTransientVariant!      # client-side discriminator if needed, or separate queries per variant
    $ckId: String!
    $columnPaths: [String!]
    $aggregationColumnPaths: [AggregationColumnInput!]
    $groupByColumnPaths: [String!]
    $streamDataArguments: StreamDataArgumentsInput
    $fieldFilter: [FieldFilterInput!]
    $rtIds: [OctoObjectId!]
    $sortOrder: [SortInput!]
    $from: DateTime
    $to: DateTime
    $limit: Int
) {
    tenant(tenantId: $tenantId) {
        streamData {
            transientStreamDataQuery @include(if: true) {
                simple(ckId: $ckId, columnPaths: $columnPaths, streamDataArguments: $streamDataArguments, sortOrder: $sortOrder, fieldFilter: $fieldFilter, rtIds: $rtIds) @include(if: $variantSimple) {
                    edges { node { rows { edges { node { cells { attributePath, value } } } } } }
                }
                # ...similarly for aggregation, groupingAggregation, downsampling with @include directives
            }
        }
    }
}
```

Simpler alternative: keep 4 fragments in one op file. Pick whichever Apollo pattern matches existing conventions in the repo.

Delete the 3 other transient `.graphql` files.

- [ ] **Step 2: Run Apollo codegen**

Agent runs codegen directly (the user has already confirmed the backend is running via the Task 7.1 first-codegen handoff):

```bash
cd /Users/reimar/dev/meshmakers/branches/main/octo-frontend-refinery-studio/src/octo-mesh-refinery-studio
npm run codegen
```

Expected: `globalTypes.ts` and per-operation types updated to the new namespaced transient shape.

- [ ] **Step 3: Commit the hand-written `.graphql` changes AND the regenerated types together**

```bash
git -C /Users/reimar/dev/meshmakers/branches/main/octo-frontend-refinery-studio add -A src/
git -C /Users/reimar/dev/meshmakers/branches/main/octo-frontend-refinery-studio commit -m "Collapse 4 transient stream-data GraphQL ops into namespaced form

Matches the TransientStreamDataQuery GraphQL namespace on the backend.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

### Task 7.3: Refactor `query-results-data-source.directive.ts`

**Files:**
- Modify: `octo-frontend-refinery-studio/src/octo-mesh-refinery-studio/src/app/tenants/repository/query-builder/data-sources/query-results-data-source.directive.ts`

- [ ] **Step 1: Collapse the 4 stream fetch methods into 1 variant-parameterized method**

Before (~270 LoC across `fetchStreamDataSimple`, `fetchStreamDataAggregation`, `fetchStreamDataGroupedAggregation`, `fetchStreamDataDownsampling`):

After (~70 LoC):

```typescript
private async fetchStreamDataTransient(variant: StreamDataTransientVariant, params: StreamDataTransientParams): Promise<StreamDataRow[]> {
    const result = await this.apollo.query({
        query: ExecuteTransientStreamDataQueryDocument,
        variables: { ...params, variant }
    });
    const node = result.data.tenant.streamData.transientStreamDataQuery[variant];
    return node.edges.flatMap(e => e.node.rows.edges.map(r => this.normalizeRow(r.node)));
}
```

Replace the 7-way `if/else` on `queryType` at lines 376-392 with a 3-way:

```typescript
if (queryType === 'simple')                           return this.fetchSimple(params);
if (queryType === 'aggregation')                      return this.fetchAggregation(params);
if (queryType === 'groupingAggregation')              return this.fetchGroupingAggregation(params);
if (queryType.startsWith('stream-data-'))             return this.fetchStreamDataTransient(queryType, params);
```

- [ ] **Step 2: Delete `mapStreamDataAggregationType` adapter function**

Both `mapStreamDataAggregationType` (lines 860-875) and `mapAggregationType` (lines 880-895) are no longer needed — the GraphQL schema now accepts the same shared `AggregationInputTypesDto` on both paths. Delete `mapStreamDataAggregationType`. Keep `mapAggregationType` (renamed if appropriate).

- [ ] **Step 3: Run Karma tests**

```bash
cd /Users/reimar/dev/meshmakers/branches/main/octo-frontend-refinery-studio/src/octo-mesh-refinery-studio
npm test -- --watch=false
```

Expected: green.

- [ ] **Step 4: Commit**

```bash
git -C /Users/reimar/dev/meshmakers/branches/main/octo-frontend-refinery-studio add src/
git -C /Users/reimar/dev/meshmakers/branches/main/octo-frontend-refinery-studio commit -m "Collapse stream-data fetch methods in query-results data source

Four fetchStreamData* methods consolidated into one variant-parameterized
method. 7-way queryType switch reduced to 3-way. mapStreamDataAggregationType
adapter deleted.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

### Task 7.4: Refactor `query-editor.component.ts`

**Files:**
- Modify: `octo-frontend-refinery-studio/src/octo-mesh-refinery-studio/src/app/tenants/repository/query-builder/query-editor/query-editor.component.ts`

- [ ] **Step 1: Consolidate the save switch**

The current 7-case save switch (lines 593-615) collapses to 3-case plus a parametric save for stream variants:

```typescript
switch (queryType) {
    case 'simple':               return this.saveSimpleQuery(form);
    case 'aggregation':          return this.saveAggregationQuery(form);
    case 'groupingAggregation':  return this.saveGroupingAggregationQuery(form);
    default:
        if (queryType.startsWith('stream-data-')) return this.saveStreamDataQuery(queryType, form);
        throw new Error(`Unknown queryType: ${queryType}`);
}
```

`saveStreamDataQuery` handles all four stream variants via a discriminated union on `queryType`. Consolidate the existing four stream-save methods' bodies.

- [ ] **Step 2: Flatten the scattered `queryType !== 'simple' && queryType !== 'stream-data-simple'` disambiguators**

Introduce a helper predicate at the top of the class:

```typescript
private readonly isSimpleLike = (t: QueryType): boolean =>
    t === 'simple' || t === 'stream-data-simple';

private readonly isAggregationLike = (t: QueryType): boolean =>
    t === 'aggregation' || t === 'stream-data-aggregation';
```

Replace every site that tests `queryType !== 'simple' && queryType !== 'stream-data-simple'` with `!this.isSimpleLike(queryType)`. Same treatment for the aggregation-related checks.

- [ ] **Step 3: Karma + manual smoke**

```bash
npm test -- --watch=false
```

Manual: start the dev stack, open the query builder, create a transient simple stream query → run → verify results. Repeat for aggregation, grouping, downsampling, and a per-type drilldown.

- [ ] **Step 4: Commit**

```bash
git -C /Users/reimar/dev/meshmakers/branches/main/octo-frontend-refinery-studio add src/
git -C /Users/reimar/dev/meshmakers/branches/main/octo-frontend-refinery-studio commit -m "Consolidate stream-data branching in query editor

7-case save switch → 3-case + parametric saveStreamDataQuery. Scattered
(queryType !== simple && queryType !== stream-data-simple) disambiguators
flattened via isSimpleLike / isAggregationLike predicates.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

---

## Final verification

After all phases, run the full test suite one more time across all backend repos + frontend:

```bash
# Backend
dotnet test /Users/reimar/dev/meshmakers/branches/main/octo-construction-kit-engine-mongodb -c DebugL 2>&1 | tail -3
dotnet test /Users/reimar/dev/meshmakers/branches/main/octo-asset-repo-services -c DebugL 2>&1 | tail -3
dotnet test /Users/reimar/dev/meshmakers/branches/main/octo-mesh-adapter -c DebugL 2>&1 | tail -3

# Frontend
cd /Users/reimar/dev/meshmakers/branches/main/octo-frontend-refinery-studio/src/octo-mesh-refinery-studio && npm test -- --watch=false
```

Expected: everything green.

Manual smoke in the browser:
- Create a persistent stream-data simple query via the UI; run it via the query results panel.
- Create a transient aggregation via the query builder; run it.
- Create a downsampling query; verify bin timestamps + aggregated values.
- Open a per-type stream drilldown; verify typed attributes appear in the result table.
- Request `.Aggregations` on a simple query (manually via GraphiQL); verify `QueryAggregationResult` shape.

Post-verification task hygiene:
- Push all feature branches.
- Open PRs against `main` in each repo.
- Note in each PR description: "Depends on the matching `feature/reimar/stream-rt-query-symmetry` branch in [other repo]".

---

## Rollback

If at any phase green tests fail irrecoverably and the work needs to be abandoned:

```bash
for repo in octo-construction-kit-engine octo-construction-kit-engine-mongodb octo-common-services octo-asset-repo-services octo-mesh-adapter octo-sdk octo-frontend-refinery-studio octo-tools; do
  git -C /Users/reimar/dev/meshmakers/branches/main/$repo checkout feature/reimar/stream-data-engine-migration 2>/dev/null \
    || git -C /Users/reimar/dev/meshmakers/branches/main/$repo checkout main
  git -C /Users/reimar/dev/meshmakers/branches/main/$repo branch -D feature/reimar/stream-rt-query-symmetry
done
```

The pre-refactor state is preserved on the original branches. No data is lost.
