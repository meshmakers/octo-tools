# Stream ↔ Runtime Query Symmetry — Design

**Date:** 2026-04-12
**Status:** Design approved, ready for implementation planning
**Related:** AB#3364 (Stream data version 2 — migration completed)
**Scope:** `octo-construction-kit-engine`, `octo-construction-kit-engine-mongodb`, `octo-asset-repo-services`, `octo-sdk`, `octo-frontend-refinery-studio`

---

## ⚠️ BRANCHING — READ FIRST

**This refactor must be done on a NEW feature branch created from the current branch, in every affected repo.** The existing `feature/reimar/stream-data-engine-migration` branch (which carries the completed AB#3364 work) stays as a fall-back. If this refactor turns out to be the wrong call, we abandon the new branch and return to the stable post-migration state without losing the previous work.

**Proposed branch name (all repos):** `feature/reimar/stream-rt-query-symmetry`

**Branching matrix — do this as the first step before any code change:**

| Repo | Current branch | Branch from | New branch |
|---|---|---|---|
| `octo-construction-kit-engine` | `feature/reimar/stream-data-engine-migration` | current | `feature/reimar/stream-rt-query-symmetry` |
| `octo-construction-kit-engine-mongodb` | `feature/reimar/stream-data-engine-migration` | current | `feature/reimar/stream-rt-query-symmetry` |
| `octo-common-services` | `feature/reimar/stream-data-engine-migration` | current | `feature/reimar/stream-rt-query-symmetry` |
| `octo-asset-repo-services` | `feature/reimar/stream-data-engine-migration` | current | `feature/reimar/stream-rt-query-symmetry` |
| `octo-mesh-adapter` | `feature/reimar/stream-data-engine-migration` | current | `feature/reimar/stream-rt-query-symmetry` |
| `octo-sdk` | `main` | current (`main`) | `feature/reimar/stream-rt-query-symmetry` |
| `octo-frontend-refinery-studio` | `main` | current (`main`) | `feature/reimar/stream-rt-query-symmetry` |
| `octo-tools` (for spec/plan docs) | `main` | current | `feature/reimar/stream-rt-query-symmetry` |

**Rollback plan:** if we decide to abandon this refactor at any point, discard the new branch(es) and check out the previous branch in each repo. The post-migration state is fully preserved on the original branches.

**Do NOT start any implementation work on the existing migration branch.** All spec-driven code changes land on the new branch.

---

## Summary

The Stream Data v2 migration moved stream-data query execution into the engine, but the GraphQL surface and CK model types remained asymmetric with their runtime-data (RT) counterparts. This design eliminates that asymmetry across four layers — CK model, engine contracts, GraphQL surface, and typed per-CkType entities — producing a single coherent query paradigm where stream queries behave structurally the same as RT queries, with deliberate exceptions only where forced by storage semantics.

Expected payoff: ~585 lines of frontend boilerplate eliminated, `StreamDataQuery.cs` shrinks from 958 LoC to ~250 LoC, three duplicate enum sets and three duplicate record types removed from engine contracts, four parallel GraphQL root fields collapsed to one.

## Goals

1. Stream data queries structurally mirror RT queries at every layer: CK model, engine contracts, GraphQL surface, source-generated per-type DTOs.
2. Stream re-uses RT's shared types where the concept is the same — `SortOrders`, `FieldFilterOperator`, `AggregationTypes`, `SortOrderItem`, `FieldFilter`, new `AggregationColumn`.
3. Typed per-CkType row classes (`Sd{CkType} : SdEntity`) emitted by the source generator, mirroring `Rt{CkType} : RtEntity`.
4. Single query-execution entry point per variant: `IStreamDataRepository.ExecuteQueryAsync`/`ExecuteAggregationQueryAsync`/`ExecuteGroupedAggregationQueryAsync`/`ExecuteDownsamplingQueryAsync`. No GraphQL-layer SQL building.

## Non-goals

- No change to `IStreamDataRepository` method signatures (only option-builder input types swap to shared RT records).
- No change to RT's GraphQL surface beyond the enum welcoming stream as a second consumer.
- No change to mesh-adapter (already on `IStreamDataRepository` via `ITenantContext.GetStreamDataRepository()`).
- No change to how CrateDB physically stores data.

## Asymmetries kept

These are forced by underlying storage and left alone:

- **Session threading.** RT resolvers plumb a MongoDB transaction session into every call; stream resolvers don't (CrateDB is stateless per operation).
- **Downsampling.** Stream has a `Downsampling` query variant; RT doesn't (no time-series concept).
- **Geospatial filter.** RT per-type connections accept a `NearGeospatialFilter`; stream doesn't (CrateDB has no spatial index usable this way).
- **Field-filter operator subset.** Stream's CrateDB mapper rejects MongoDB-specific operators (`MatchRegEx`, `AnyEq`, `AnyLike`, `Match`, `Contains`, `StartsWith`, `EndsWith`) with `NotSupportedException`. Supported: `Equals`, `NotEquals`, `LessThan`, `LessEqualThan`, `GreaterThan`, `GreaterEqualThan`, `Like`, `In`, `NotIn`, `IsNull`, `IsNotNull`, `Between` (with `SecondaryValue`).

---

## Design

### 1. Shared engine contracts

**Types deleted** from `octo-construction-kit-engine/src/Runtime.Contracts/StreamData/`:

| Deleted type | Replacement (existing in RT contracts) |
|---|---|
| `StreamDataSortDirection` (2 values) | `SortOrders` (3 values — stream ignores `Default`) |
| `StreamDataSortOrder` record | `SortOrderItem` |
| `StreamDataFieldFilterOperator` (7 values) | `FieldFilterOperator` (19 values — stream uses subset) |
| `StreamDataFieldFilter` record | `FieldFilter` (inc. `SecondaryValue` used for `Between`) |
| `StreamDataAggregationFunction` (5 values) | `AggregationTypes` (CK-generated, same 5 values) |
| `StreamDataAggregationColumn` record | **NEW** `AggregationColumn { AttributePath, Function: AggregationTypes }` in `Runtime.Contracts/Repositories/Query/` |

**Types kept stream-specific** (legitimate domain differences): `StreamDataPoint` (insert side), `StreamDataRow` (engine output — dict values), `StreamDataQueryResult`, option builders (`StreamDataQueryOptions` and three variants). Option-builder `With*` signatures swap to shared types.

**`StreamDataRow` gets two extra typed fields:** `RtCreationDateTime: DateTime?` and `RtChangedDateTime: DateTime?`. These match the physical CrateDB schema (already selected by `IncludeDefaultVariables`) and the additions to `SdEntity`. Today they land in `Values`; after the refactor they surface as typed fields. `StreamDataPoint` (insert side) gets the same fields so producers can write them explicitly when known.

**CrateDB operator mapper** added inside `CrateDbStreamDataRepository`. Supports `Between` via SQL `BETWEEN` using both `ComparisonValue` and `SecondaryValue`. Throws `NotSupportedException("operator X not supported for stream data queries against CrateDB")` for unsupported operators.

### 2. CK model alignment

**Current state** (`SystemCkModel/ConstructionKit/types/query.yaml`):

```
PersistentQuery (abstract)
 ├─ SimpleRtQuery, AggregationRtQuery, GroupingAggregationRtQuery
 ├─ StreamDataSimpleQuery
 ├─ StreamDataAggregationQuery
 ├─ StreamDataGroupingAggregationQuery
 └─ StreamDataDownsamplingQuery
```

**Target state:**

```
PersistentQuery (abstract)
 ├─ SimpleRtQuery, AggregationRtQuery, GroupingAggregationRtQuery
 └─ StreamDataQuery (abstract — NEW intermediate base)
     │ common stream attrs: RtIds?, From?, To?, Limit?, FieldFilter?
     ├─ SimpleSdQuery              { Columns, Sorting? }
     ├─ AggregationSdQuery         { Columns (AggregationQueryColumns) }
     ├─ GroupingAggregationSdQuery { GroupingColumns, Columns }
     └─ DownsamplingSdQuery        { Columns, From (required), To (required), Limit (required) }
```

**Naming convention (RT parity):** rename `StreamData{Variant}Query` → `{Variant}SdQuery`. Generated C# classes become `RtSimpleSdQuery`, `RtAggregationSdQuery`, `RtGroupingAggregationSdQuery`, `RtDownsamplingSdQuery`, with shared abstract `RtStreamDataQuery`.

Reads: `Rt` = "runtime instance of", `Sd` = "stream-data flavor". So `RtSimpleSdQuery` = "runtime instance of a simple stream-data query".

**Attribute shape sharing** (already in place unless noted):
- `AggregationQueryColumns` — shared between RT and stream aggregation variants.
- `Query.GroupByColumns`, `Query.FieldFilter`, `Query.Sorting` — shared.
- `StreamDataQuery.Columns`, `StreamDataQuery.RtIds`, `StreamDataQuery.From`, `StreamDataQuery.To`, `StreamDataQuery.Limit` — stream-only, move to the abstract `StreamDataQuery` base.

### 3. Typed stream entities (`Sd*`)

**New engine type** `SdEntity` in `Runtime.Contracts/StreamData/`:

```csharp
public abstract class SdEntity
{
    public OctoObjectId RtId { get; set; }
    public RtCkId<CkTypeId> CkTypeId { get; set; } = null!;
    public DateTime Timestamp { get; set; }
    public string? RtWellKnownName { get; set; }
    public DateTime? RtCreationDateTime { get; set; }
    public DateTime? RtChangedDateTime { get; set; }
    public AttributesCollection Attributes { get; set; } = new();
}
```

Mirrors `RtEntity` with two additions: `Timestamp` for the data point's time-series position, and both entity provenance datetimes (`RtCreationDateTime`, `RtChangedDateTime`) preserved alongside — same as the physical CrateDB schema and what `CrateQueryBuilder.IncludeDefaultVariables` selects today. `Attributes` retained so every attribute is reachable even when typed properties are used.

**Source generator extensions:**

1. `octo-construction-kit-engine/src/ConstructionKit.SourceGeneration/CkTypeCodeGenerator.cs`: for each CK type with `isDataStream` attributes, also emit `Sd{CkType} : SdEntity` with strongly-typed properties for data-stream attributes.

2. `octo-sdk/src/Sdk.SourceGeneration/QueryDtoCodeGenerator.cs`: for each CK type with `isDataStream` attributes, emit `Sd{CkType}DtoType : ObjectGraphType<Sd{CkType}>`.

**Hydration helper** (engine-mongodb, `StreamData/`):

```csharp
public static TEntity HydrateSdEntity<TEntity>(StreamDataRow row) where TEntity : SdEntity, new();
```

Uses reflection to map dict keys to typed properties; keeps `Attributes` populated. Single implementation for all `Sd*` subtypes — CK-metadata-agnostic.

**Type dispositions:**
- `StreamDataEntityDto` — **delete**. Replaced by `Sd{CkType}`.
- `StreamDataQueryRowDto` — **keep**. Used by cells-based paths: generic connection, descriptor `.Rows` when loaded query is aggregation/grouping/downsampling (dynamic columns).

### 4. GraphQL surface: persistent query descriptor

**Root collapse** (four peers → one) in `StreamDataQuery.cs` (mounted as `StreamData.*` under `OctoQuery`):

```csharp
Connection<StreamDataQueryDtoType>("StreamDataQuery")
    .Argument<NonNullGraphType<OctoObjectIdType>>("rtId", "The persisted stream-data query runtime id.")
    .ResolveAsync(ResolveStreamDataQueryAsync);
```

**Descriptor type:**

```csharp
internal sealed class StreamDataQueryDto : GraphQlDto
{
    public required OctoObjectId QueryRtId { get; init; }
    public required RtCkId<CkTypeId> AssociatedCkTypeId { get; init; }
    public required IReadOnlyList<RtQueryColumn> Columns { get; init; }   // reused from RT
    public required StreamDataQueryUserContext UserContext { get; init; }
}

internal sealed class StreamDataQueryUserContext
{
    public required RtStreamDataQuery LoadedQuery { get; init; }   // base class; polymorphic dispatch
}
```

**Root resolver** loads the `RtStreamDataQuery` subtype, builds the descriptor, wraps in a single-element `OctoConnection`. No DB-side query execution.

**Sub-connections on `StreamDataQueryDtoType`:**

- `.Rows(streamDataArguments, sortOrder)` — dispatches on `LoadedQuery` runtime type to the right `streamDataRepo.Execute*Async` call; returns cells-based rows via `StreamDataQueryRowDto`.
- `.Aggregations(aggregations)` — runs an additional `ExecuteAggregationQueryAsync` over the query's filter set with requested statistics; returns `QueryAggregationResult` (same GraphQL shape as RT).

`.Aggregations` is GraphQL-conditional — skipping it in the query skips the extra backend call.

### 5. GraphQL surface: transient query namespace

**Root collapse** (four flat peers → namespace):

```csharp
Field<NonNullGraphType<StreamDataTransientQuery>>("TransientStreamDataQuery")
    .Description("Transient stream-data queries")
    .Resolve(_ => new { });
```

**New namespace type** `StreamDataTransientQuery`, mirroring RT's `RtTransientQuery`:

```graphql
TransientStreamDataQuery {
    Simple(ckId, columnPaths, streamDataArguments, sortOrder, fieldFilter, rtIds)
    Aggregation(ckId, columnPaths, streamDataArguments, fieldFilter, rtIds)
    GroupingAggregation(ckId, groupByColumnPaths, columnPaths, streamDataArguments, fieldFilter, rtIds)
    Downsampling(ckId, columnPaths, limit, from, to, fieldFilter, rtIds)
}
```

Each sub-connection resolver reads args, validates via `StreamDataFieldValidation`, builds a `StreamDataTransientQueryUserContext`, returns a `StreamDataTransientQueryDto` descriptor. No DB hit yet.

**Transient descriptor** has `.Rows` and `.Aggregations` sub-connections identical in shape to the persistent descriptor. Internal dispatcher keys off `UserContext.Variant`.

**Shared execution helper:**

```csharp
private static async Task<StreamDataQueryResult> ExecuteVariantAsync(
    IStreamDataRepository repo,
    QueryVariant variant,
    RtCkId<CkTypeId> ckTypeId,
    /* ...common args... */);
```

Used by both persistent and transient descriptor `.Rows` resolvers. Reads its arg shape from the respective `UserContext`.

### 6. Per-type and generic connections

**Generic endpoint** `StreamDataEntities(ckId:…)` — new, mirroring RT's `RuntimeEntities`:

```csharp
Connection<StreamDataEntityGenericDtoType>("StreamDataEntities")
    .Argument<NonNullGraphType<StringGraphType>>("ckId", …)
    .Argument<NonNullGraphType<ListGraphType<NonNullGraphType<StringGraphType>>>>("columnPaths", …)
    .Argument<StreamDataArgumentsGraphType>("streamDataArguments", …)
    .Argument<ListGraphType<SortDtoType>>("sortOrder", …)
    .Argument<ListGraphType<FieldFilterDtoType>>("fieldFilter", …)
    .Argument<ListGraphType<OctoObjectIdType>>("rtIds", …)
    .ResolveAsync(ResolveStreamDataEntitiesAsync);
```

Returns cells-based rows via `StreamDataEntityGenericDtoType` (new — the cells-based counterpart to `RtEntityGenericDtoType`).

**Per-type connections** (one per CK type with `isDataStream` attributes, via `GetStreamTypes()`):

```csharp
foreach (var sdEntityDtoType in graphTypesCache.GetStreamTypes())
{
    this.Connection<object?, IGraphType, SdEntity>(graphTypesCache, sdEntityDtoType, sdEntityDtoType.Name)
        .AddMetadata(Statics.CkId, sdEntityDtoType.CkTypeId.ToRtCkId())
        .Argument<OctoObjectIdType>("rtId", …)
        .Argument<ListGraphType<OctoObjectIdType>>("rtIds", …)
        .Argument<StreamDataArgumentsGraphType>("streamDataArguments", …)
        .Argument<ListGraphType<SortDtoType>>("sortOrder", …)
        .Argument<ListGraphType<FieldFilterDtoType>>("fieldFilter", …)
        .ResolveAsync(ResolveStreamDataEntitiesByTypeAsync);
}
```

**Per-type resolver** funnels through `StreamDataQueryOptions` + `IStreamDataRepository` (no more `CrateQueryBuilder`):

1. Read `ckTypeId` from metadata.
2. Walk `fieldContext.Fields` → derive `columnPaths` (auto-projection from GraphQL selection set — preserved).
3. Build `StreamDataQueryOptions`.
4. `streamDataRepo.ExecuteQueryAsync(options)`.
5. Hydrate rows via `HydrateSdEntity<Sd{CkType}>`.

**Deleted helpers** (from `StreamDataQuery.cs`): `HandleRequestedAttributes`, `HandleRequestedRtIds`, `AddVariable`, `ExecutePaginatedStreamDataQueryAsync`. Replaced by a single `DeriveColumnPathsFromSelection` helper (~30 LoC). `BuildFieldResolver` is kept — still used for field-name validation.

### 7. Engine internals cleanup

**Visibility changes** (`octo-construction-kit-engine-mongodb/src/Runtime.Engine.MongoDb/StreamData/QueryBuilder/`):

- `CrateQueryBuilder` — public → internal
- `CrateQueryCompiler` — public → internal
- `QueryBuilderException` — public → internal

**Test access:** `InternalsVisibleTo("Meshmakers.Octo.Runtime.Engine.MongoDb.StreamData.UnitTests")`.

**Public surface after cleanup** (stream engine):

| Type | Status |
|---|---|
| `IStreamDataRepository` | Public — sole execution entry point |
| `StreamDataQueryOptions` + 3 variant builders | Public |
| `StreamDataPoint`, `StreamDataRow`, `StreamDataQueryResult` | Public |
| `SdEntity` (new) | Public |
| `StreamDataFieldResolver`, `StreamDataField`, `StreamDataFieldCategory` | Public |
| `Constants` (TimestampAlias, DefaultStreamDataFields) | Public |
| `CrateDatabaseClient`, `IStreamDataDatabaseClient` | Public (test fixtures) |
| `CrateQueryBuilder`, `CrateQueryCompiler`, `QueryBuilderException` | Internal |
| `QueryModeDto` | Delete if unused after refactor |

**Unused-API prune:** audit `CrateQueryBuilder` public methods post-migration; remove those no longer called (candidates: filter-operator overloads only used by deleted GraphQL helpers).

---

## Implementation phases

Seven phases. Each compiles and passes tests on its own.

### Dependency chain

```
Phase 1 (shared contracts)  ─┐
                             ├─► Phase 4 (descriptors)
Phase 2 (CK model rename)  ──┤
                             │
Phase 3 (SdEntity + codegen)─┴─► Phase 5 (per-type + generic) ─► Phase 6 (internals) ─► Phase 7 (frontend)
```

### Phase 1 — Shared engine contracts

- Introduce `AggregationColumn` record in `Runtime.Contracts/Repositories/Query/`.
- Delete six stream types (3 enums + 3 records) from `Runtime.Contracts/StreamData/`.
- Update four option builders to take shared RT types.
- Update `StreamDataGraphQlMapper` (GraphQL DTO → shared engine types).
- Add CrateDB operator mapping including `Between`; throw `NotSupportedException` for unsupported ops.
- Update stream unit + integration tests.
- **Verification:** existing GraphQL behavior unchanged; new `Between` works via timestamp-range integration test.

### Phase 2 — CK model alignment

- Add abstract `StreamDataQuery` base type in `SystemCkModel/ConstructionKit/types/query.yaml`.
- Rename `StreamData{Variant}Query` → `{Variant}SdQuery`.
- Move `RtIds`/`From`/`To`/`Limit`/`FieldFilter` to the abstract base.
- Update references: `StreamDataQuery.cs` resolver generic args, integration test fixtures, downstream CK model consumers (grep `octo-construction-kit/`).
- **Verification:** asset-repo + engine-mongodb compile; stream integration tests pass.

### Phase 3 — Source generator + `SdEntity`

- Add `SdEntity` base class.
- Extend `CkTypeCodeGenerator.cs` to emit `Sd{CkType}` for data-stream CK types.
- Extend `QueryDtoCodeGenerator.cs` to emit `Sd{CkType}DtoType`.
- Add `HydrateSdEntity<T>(StreamDataRow)` helper.
- **Verification:** test CK model emits `SdMeteringPoint` / `SdMeteringPointDtoType`; hydrator unit test.

### Phase 4 — Persistent + transient descriptors (bundled)

- Add `StreamDataQueryDto`, `StreamDataQueryDtoType`, `StreamDataTransientQuery`, `StreamDataTransientQueryDto`, `StreamDataTransientQueryDtoType`.
- Extract shared `ExecuteVariantAsync` helper.
- Replace 4 persistent + 4 transient top-level roots with 1 persistent + 1 transient-namespace.
- Delete old resolvers.
- `StreamDataQuery.cs` shrinks to ~300 LoC.
- **Verification:** all stream integration tests updated; new `.Aggregations` tests on both persistent and transient paths.

### Phase 5 — Per-type migration + generic endpoint

- Rewrite per-type resolver through `StreamDataQueryOptions` + `IStreamDataRepository`.
- Hydrate rows via `HydrateSdEntity<Sd{CkType}>`.
- Add generic `StreamDataEntities(ckId)` connection with new `StreamDataEntityGenericDtoType`.
- Delete four field-introspection helpers; extract `DeriveColumnPathsFromSelection`.
- `StreamDataQuery.cs` now ~250 LoC.
- **Verification:** per-type returns typed rows; generic returns cells; no `CrateQueryBuilder` reference in asset-repo GraphQL project.

### Phase 6 — Engine internals cleanup

- Flip `CrateQueryBuilder`/`CrateQueryCompiler`/`QueryBuilderException` to internal.
- Add `InternalsVisibleTo`.
- Delete `QueryModeDto` if unused.
- Prune dead `CrateQueryBuilder` public methods.
- **Verification:** engine-mongodb + asset-repo compile; 51 unit tests pass.

### Phase 7 — Frontend migration

- Rewrite Apollo `.graphql` ops.
- Collapse 4 stream transient `.graphql` files to 1.
- Refactor `query-results-data-source.directive.ts`: 4 stream fetch methods → 1 variant-parameterized method; 7-case `queryType` switch → 3-case.
- Delete `mapStreamDataAggregationType` adapter (~35 LoC).
- Refactor `query-editor.component.ts`: 7-case save switch → 3-case; flatten scattered stream-vs-RT disambiguators.
- **Verification:** Karma green; manual smoke test all query types; ~585 LoC deleted.

---

## Testing strategy per phase

- **Phase 1:** rerun existing tests + new `Between` integration tests.
- **Phase 2:** rerun existing integration tests with updated type names.
- **Phase 3:** unit test that hydrator populates typed `Sd*` properties from a `StreamDataRow`.
- **Phase 4:** new integration tests for `.Aggregations` sub-connection; old 8 top-level-root tests rewritten to new shape.
- **Phase 5:** rewrite per-type test to assert typed-row output; new generic-connection integration test.
- **Phase 6:** no new tests (compile-time guarantee).
- **Phase 7:** Karma + manual smoke.

## Breaking changes

All acceptable (no customer currently uses stream data queries, confirmed by stakeholder):

1. **CK YAML type rename:** `StreamData{Variant}Query` → `{Variant}SdQuery`. Any downstream CK model package referencing these must update.
2. **C# type rename:** `RtStreamData{Variant}Query` → `Rt{Variant}SdQuery`. All C# callers update.
3. **Engine enum/record deletion:** `StreamData{SortDirection,FieldFilterOperator,AggregationFunction,SortOrder,FieldFilter,AggregationColumn}` — replaced by shared RT types.
4. **GraphQL surface breaking:** 4 stream persistent roots + 4 stream transient roots collapse to 1 + 1-namespace.
5. **Stored data:** MongoDB documents of old type names orphaned (no migration script — dev caches wipe acceptable).

## Open questions

None at design time. Deferred to planning/implementation:

- Whether any CK model migration script is worth authoring for dev-environment convenience — Phase 2 task.
- Whether pruning of `CrateQueryBuilder` public methods warrants a separate commit within Phase 6.
