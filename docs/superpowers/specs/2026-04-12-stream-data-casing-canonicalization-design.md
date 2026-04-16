# Stream-data casing canonicalization — design

**Status:** draft
**Date:** 2026-04-12
**Scope:** stream-data path only (asset-repo + engine-mongodb + `Runtime.Contracts` stream-data contracts). Engine-wide casing cleanup is explicitly out of scope — see "Non-goals" below.

## Problem

Every feature that touches stream-data code has required "fix the casing" debugging. Recent examples from the current PR cycle:

- `timeStamp` vs `timestamp` drift between the generic `streamDataEntities` endpoint and the per-type `stream*` connections (fixed in `octo-asset-repo-services` commit `c00deac`: explicit field-name override).
- Null `state` / `type` / other typed attribute fields on per-type connections because `StreamDataRow.Values` was keyed by camelCase `GraphQlAlias` while `RtTypeWithAttributes.GetAttributeValueOrDefault` does a case-sensitive lookup against PascalCase `AttributeName` (fixed in commit `23dea1e`: rekey in `ConvertToDataPointDto`).
- Earlier: frontend sort / filter `attributePath` casing mismatches.

The root cause is systemic, not isolated. Attribute names cross ~8 layers in the stream-data path (wire → resolver → query options → engine repo → SQL alias → CrateDB column → row value dictionary → DTO attribute bag → typed field resolver). Each layer currently picks its own form. Drift is inevitable because there is no enforced convention.

The CK cache already provides `CkTypeAttributeGraph.AttributeName` (PascalCase) as the authoritative source of truth. `StreamDataFieldResolver` (engine-mongodb) already maps case-insensitive input to canonical `{CrateDbName: PascalCase, GraphQlAlias: camelCase}`. The infrastructure is there — callers just don't consistently route through it.

## Goal

Lock in one rule so that adding a new stream-data feature requires zero casing decisions from the author:

> **Inside the backend, every attribute name and attribute path is PascalCase dotted.** camelCase exists only on the GraphQL wire, converted at exactly two boundaries (inbound client input, outbound cells `attributePath`). Every backend layer between those boundaries keys attribute names in PascalCase.

## Non-goals

- **Engine-wide cleanup.** `RtPathEvaluator`, `RuntimeEntity` graph queries, and association navigation are already PascalCase-canonical internally. No changes there.
- **Typed `ResolvedField` signatures across the API.** Evaluated, rejected: the type-safety guarantee leaks at both ends (GraphQL variable strings in, `Field(string name, ...)` schema registration out), and it would force parallel typed-path infrastructure beside `RtPathEvaluator`'s string-based contracts — scope creep for modest additional safety.
- **Navigation (`->`), array indexing (`[n]`), or type-cast path tokens** for stream data. Stream data points are flat time-series rows; association traversal is out of scope. `ResolvePath` rejects inputs containing these tokens with a clear error. If future work needs them, the existing `RtPathEvaluator.TokenizePath` is the natural extension point.
- **Dotted record paths on stream attributes.** An audit across every shipped CK package (Environment, EnergyCommunity, Industry.Basic, Industry.Basic.Energy, etc.) found zero stream attributes declared with `valueType: Record`. Stream data in practice is always flat scalars (String/Double/Int/Enum/DateTime). The plan originally included `ResolvePath` + record traversal for "future-proofing"; the CK-graph-aware branch of `ResolvePath` is preserved as defensive code but is unreachable in production because no caller threads a `CkTypeGraph` through, and no real query uses dotted `columnPaths`. If a future CK package ever declares a record-typed stream attribute, four wiring sites will need updates (`StreamDataFieldValidation`, the 6 `fieldResolver.Resolve` call sites in `CrateDbStreamDataRepository`, chained bracket emission in the CrateDB query compiler, and nested-dict→`RtRecord` hydration in `StreamDataEntityDtoType.ResolveAttributeValue`). Not worth paying that cost until a real use case appears.
- **Wire format changes.** `cells.items[].attributePath` stays camelCase dotted. Frontend is untouched.

## Why Option 2 (PascalCase canonical) over Option 1 (typed ResolvedField)

Considered and rejected: introduce a `ResolvedField` / `ResolvedPath` value type and thread it through every stream-data method signature instead of raw strings.

- **Consistency:** `RtPathEvaluator` already enforces PascalCase internally (calls `.ToPascalCase()` on every path segment before lookup against `AllAttributesByName`). Option 2 extends an existing codebase-wide contract into stream-data. Option 1 invents a new parallel convention.
- **Path evolution:** Paths like `Issuer.CompanyName` are expected for stream-data (record-typed attributes). Option 2 extends the resolver segment-by-segment; internal storage is a single canonical dotted string (`"Issuer.CompanyName"`). Option 1 requires the resolved type to carry structured path info plus bridge code at every `RtPathEvaluator` call site — engine-wide scope creep.
- **Blast radius:** Option 2 ≈ 30 LoC across ~5 files, shippable alongside Phase 7. Option 1 ≈ signature cascade across ~8+ files and a separate phase.
- **Type-safety ceiling:** Option 1's guarantee leaks at the wire boundary (GraphQL arrives as strings) and the schema-registration boundary (`Field(string name, ...)` takes strings). Actual drift prevention in practice: ~70%. Option 2 with the invariant-pinning test: functionally equivalent, far less churn.

## Architecture

One rule, two conversion points.

**Rule:** Attribute names / paths inside the backend are PascalCase dotted strings. Period.

**Inbound boundary** (wire → canonical): `StreamDataFieldResolver.ResolvePath(input)` is the single entry. Callers never hand-convert.
- Input: any casing (client-supplied).
- Output: `ResolvedPath { PascalCaseDotted, CamelCaseDotted, LeafAttribute }`, or `null` if unresolvable.
- Case-insensitive input matching (preserves today's tolerance).

**Outbound boundary** (canonical → wire):
- GraphQL schema `Field(attributeName, ...)` registration passes PascalCase; GraphQL.NET's default naming convention camelCases on the wire.
- `cells.items[].attributePath` emitted by the cells-based resolvers uses `resolvedPath.CamelCaseDotted` — a single translation call, not ad-hoc `.ToCamelCase()`.

**In between**, every layer uses PascalCase dotted. No exceptions.

## Components

### Modified

**`StreamDataFieldResolver` (`octo-construction-kit-engine-mongodb/.../StreamData/`)**

- New method `ResolvedPath? ResolvePath(string input, CkTypeGraph ckTypeGraph)`. Tokenizes dotted input (reusing `RtPathEvaluator.TokenizePath` for segment extraction; rejects `->`, `[`, `::`), resolves each segment against the parent CK type:
  - First segment: top-level attribute on `ckTypeGraph` via `fieldResolver._fields` lookup (case-insensitive).
  - Subsequent segments: record attribute on the previous segment's leaf type via `CkTypeAttributeGraph.ValueCkRecordId` → `ckCacheService.GetRtCkRecord(...)` → `AllAttributesByName` (PascalCase lookup).
- Returns `ResolvedPath { PascalCaseDotted, CamelCaseDotted, LeafAttribute: CkTypeAttributeGraph | CkRecordAttributeGraph }`.
- Existing `Resolve(string)` stays as-is for flat input. Callers that need path-aware resolution must explicitly use `ResolvePath`. No compatibility adapter — it's two APIs: `Resolve` for flat names (today's behaviour unchanged), `ResolvePath` for dotted input.

**`CrateDbStreamDataRepository.MapToStreamDataRow`**

- Switches the `values` dictionary to key by `resolved.CrateDbName` (PascalCase dotted) instead of `resolved.GraphQlAlias` (camelCase).
- Aggregation path in `ExecuteAggregationQueryAsync`: `outputNameBySqlAlias` maps SQL alias (e.g. `AVG_Voltage`) → `CrateDbName` (PascalCase) instead of `GraphQlAlias`. Downstream rekey continues to work transparently.

**`StreamDataQuery.ConvertToDataPointDto` (asset-repo)**

- Collapses to trivial `new DataPointDto(new Dictionary<string, object?>(row.Values))`. The rekey added in commit `23dea1e` (camelCase → PascalCase) becomes redundant and is removed. Accompanying comment removed.

**`StreamDataQueryRowDtoType.ResolveCells` + `StreamDataEntityGenericDtoType` cells resolver (asset-repo)**

- Output `attributePath` translates PascalCase → camelCase via `fieldResolver.Resolve(key).GraphQlAlias`. Today both resolvers pass the raw key through, which was already camelCase — under the new rule, they must translate explicitly.

**`StreamDataEntityDto.TimeStamp` (`octo-sdk/.../Communication.Contracts/DataTransferObjects/`)**

- Rename property from `TimeStamp` (two words) to `Timestamp` (one word). Matches `StreamDataRow.Timestamp` and `DataPointDto.Timestamp`. Removes the need for the explicit `Field<DateTimeGraphType>("timestamp")` override added in commit `c00deac`.

### Removed

- Explicit field-name override in `StreamDataEntityDtoType.cs:64-68` (no longer needed after the DTO property rename).
- The casing-explanation comment in `ConvertToDataPointDto`.

### Added

**Unit tests** (`octo-construction-kit-engine-mongodb/tests/StreamData.UnitTests/StreamDataFieldResolverPathTests.cs`):

| Test | Expected |
|---|---|
| `ResolvePath_FlatName_ReturnsCanonicalForms` | `ResolvePath("Voltage")` → `PascalCaseDotted="Voltage"`, `CamelCaseDotted="voltage"` |
| `ResolvePath_CaseInsensitiveInput_Normalizes` | `ResolvePath("voltage")` → same result as above |
| `ResolvePath_RecordSegment_ResolvesThroughCkGraph` | `ResolvePath("Issuer.CompanyName")` → `"Issuer.CompanyName"` / `"issuer.companyName"` |
| `ResolvePath_UnknownSegment_ReturnsNull` | `ResolvePath("Issuer.NotAField")` → `null` |
| `ResolvePath_UnsupportedNavigationToken_Rejected` | `ResolvePath("Voltage->Owner")` throws `NotSupportedException` or returns `null` with diagnostic |
| `ResolvePath_EmptyOrNull_ReturnsNull` | boundary cases |
| `Resolve_FlatInput_BackwardCompatible` | existing callers unchanged |

**Integration tests** (asset-repo):

- `StreamDataPerTypeConnectionTests.PerTypeConnection_RowValuesAreKeyedInPascalCase` — invariant pin at the engine layer. Executes a query, exposes a test hook on the fixture to inspect the engine-level `StreamDataRow.Values`, asserts every key matches the PascalCase convention (no lowercase first character).
- `StreamDataSimpleQueryTests.TransientSimpleQuery_CellsAttributePathIsCamelCase` — invariant pin at the outbound wire boundary. Selects `cells { items { attributePath } }`, asserts camelCase format.
- `StreamDataPathQueryTests.PerTypeConnection_RecordPathResolves` (new file) — extends `MeteringPoint` with a `Location: Coordinates { Latitude, Longitude }` record attribute, queries `simple(columnPaths: ["location.latitude"])`, asserts the result cell has `attributePath: "location.latitude"` and the value matches. End-to-end path flow.

### Not touched

- `RtTypeWithAttributes` base class — case-sensitive lookup stays. We align with its docstring ("The name of the property in PascalCase").
- `RtPathEvaluator` — already canonical.
- Frontend — wire format unchanged.
- Test fixtures other than the one that needs a record-typed attribute added.

## Data flow

One query trip to make the invariant visible at each stage.

```
Client query:
  transientStreamDataQuery.simple(
    ckId: "Industry.Basic/Alarm",
    columnPaths: ["state", "issuer.companyName"])   ← camelCase dotted (wire)

  ↓ StreamDataQuery resolver calls fieldResolver.ResolvePath(input, ckTypeGraph) per column

ResolvedPath { PascalCaseDotted: "State",              CamelCaseDotted: "state",              LeafAttribute: State }
ResolvedPath { PascalCaseDotted: "Issuer.CompanyName", CamelCaseDotted: "issuer.companyName", LeafAttribute: CompanyName }

  ↓ StreamDataQueryOptions.WithColumns(["State", "Issuer.CompanyName"])   ← PascalCase dotted
  ↓ CrateDbStreamDataRepository builds SQL using PascalCase column aliases
  ↓ MapToStreamDataRow produces StreamDataRow.Values = {
      "State": "Active",
      "Issuer.CompanyName": "Acme"
    }   ← PascalCase dotted keys (canonical internal form)

Per-type branch:
  ConvertToDataPointDto → DataPointDto.Attributes (PascalCase keys)
  ResolveAttributeValue → GetAttributeValueOrDefault("State") / ("Issuer.CompanyName") — hits
  GraphQL.NET camelCases the registered field name on the wire

Cells-based branch:
  ResolveCells translates each key: attributePath = fieldResolver.Resolve(key).GraphQlAlias
  Wire: cells.items = [
    { attributePath: "state",              value: "Active" },
    { attributePath: "issuer.companyName", value: "Acme"   }
  ]
```

### The invariant, tabulated

| Stage | Form |
|---|---|
| Wire (client ↔ server) | camelCase dotted |
| Resolver entry (after `ResolvePath`) | PascalCase dotted |
| `StreamDataQueryOptions.Columns` | PascalCase dotted |
| SQL column aliases in CrateDB | PascalCase dotted |
| `StreamDataRow.Values` keys | **PascalCase dotted** (changed) |
| `DataPointDto.Attributes` keys | PascalCase dotted |
| `RtTypeWithAttributes.GetAttributeValueOrDefault` arg | PascalCase dotted (unchanged) |
| `Field(attributeName, …)` registration | PascalCase (GraphQL.NET camelCases on wire) |
| `cells.items[].attributePath` on wire | camelCase dotted (translated at output) |

Two boundaries, PascalCase everywhere in between. Any code that violates this is catchable by the invariant-pinning integration test.

## Error handling & edge cases

**Aggregation SQL aliases.** `{func}_{name}` pattern (e.g. `AVG_Voltage`) uses `CrateDbName` (PascalCase). Downstream `outputNameBySqlAlias` rekey already maps to output name — flip that output name from `GraphQlAlias` to `CrateDbName`. Aggregation rows land in `row.Values` following the same invariant.

**Default fields.** `Constants.DefaultStreamDataFields` (`Timestamp`, `RtId`, `CkTypeId`, …) is already PascalCase. `MapToStreamDataRow`'s switch keys on the PascalCase constants (`Constants.RtId`, `Constants.Timestamp`, …) instead of the `*Alias` constants. The `*Alias` constants become internal-only to `StreamDataFieldResolver` (which uses them to emit the camelCase `GraphQlAlias` on its `ResolvedField` / `ResolvedPath` entries); cells-based output goes through the resolver, not the constants directly. Unused `*Alias` constants that fall out of the cleanup are deleted in the same commit.

**Unknown / typo'd input.** `Resolve(...)` / `ResolvePath(...)` returns `null`. Caller raises GraphQL validation error via existing `StreamDataFieldValidation.ValidateStreamDataFields`.

**Unresolvable path segment.** `ResolvePath("Issuer.NotAField")` returns `null` with diagnostic indicating the failed segment. Matches `RtPathEvaluator`'s `InvalidPathException` pattern.

**Unsupported path tokens.** `->`, `[n]`, `::` rejected explicitly with `NotSupportedException` or a typed error distinguishing "unknown attribute" from "unsupported path construct".

**Wire-format stability.** `cells.items[].attributePath` must stay camelCase. The per-variant cells integration tests (Section 2) catch any forgotten output-boundary translation.

**Performance.** `ResolvePath` runs once per selected column at resolver entry, not per row. Negligible.

## Implementation order

Recommended build sequence:

1. `StreamDataFieldResolver.ResolvePath` + unit tests (in isolation, no callers yet).
2. Rename `StreamDataEntityDto.TimeStamp` → `Timestamp` in `octo-sdk`; rebuild asset-repo.
3. Flip `CrateDbStreamDataRepository.MapToStreamDataRow` to use `CrateDbName` keys; update aggregation path.
4. Simplify `StreamDataQuery.ConvertToDataPointDto`; remove rekey.
5. Add translation at cells-based output sites (`StreamDataQueryRowDtoType.ResolveCells`, `StreamDataEntityGenericDtoType` cells resolver).
6. Remove the `Field<DateTimeGraphType>("timestamp")` override in `StreamDataEntityDtoType`.
7. Add invariant-pinning + path integration tests.
8. One commit per repo. Cross-repo dependency ordering: `octo-sdk` (DTO rename) must land and be picked up via `Invoke-Build` before `octo-construction-kit-engine-mongodb` and `octo-asset-repo-services` rebuild. All three on `feature/reimar/stream-rt-query-symmetry`.

## Open questions

None — spec is complete for handoff to the implementation-planning phase.
