# Stream-data Casing Canonicalization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Lock in one rule for the stream-data path — PascalCase dotted attribute names internally, camelCase dotted only on the GraphQL wire — so that future stream-data features need zero casing decisions.

**Architecture:** `StreamDataFieldResolver` becomes the single gatekeeper between wire casing (camelCase) and internal casing (PascalCase). `StreamDataRow.Values` and `DataPointDto.Attributes` key by PascalCase. Cells-based GraphQL resolvers translate PascalCase→camelCase at the output boundary using a new paired `ColumnNameMapping` record carried on `StreamDataQueryRowDto`.

**Tech Stack:** .NET 10, GraphQL.NET, xUnit v3 + FluentAssertions (.NET), CrateDB (test containers via Testcontainers).

**Spec:** `docs/superpowers/specs/2026-04-12-stream-data-casing-canonicalization-design.md`

**Wave:** Wave 3 of the stream/rt query symmetry work. Wave 2 (Phases 1–7) is parked on `feature/reimar/stream-rt-query-symmetry` across 9 repos, 61 commits, tests green. See "Starting checkpoint" below.

**Repos touched (all on new branch `feature/reimar/stream-data-casing`, branched from the wave-2 tip):**
- `octo-sdk` — DTO property rename
- `octo-construction-kit-engine-mongodb` — `ResolvePath`, `MapToStreamDataRow` flip, unit tests
- `octo-asset-repo-services` — cells-translation refactor, simplify `ConvertToDataPointDto`, integration tests
- `octo-tools` — this plan doc

---

## Starting checkpoint (wave-2 tip, 2026-04-13)

The wave-3 branch `feature/reimar/stream-data-casing` was created from these commits on `feature/reimar/stream-rt-query-symmetry`. All nine wave-2 repos are listed for provenance even though only four are touched in wave 3 — the runtime behaviour under test depends on the full wave-2 delta being present in the DebugL build chain.

| Repo | Wave-2 tip SHA | Subject |
|---|---|---|
| `octo-construction-kit-engine` | `f3a2b74` | Add SetAttributeRawValue to RtTypeWithAttributes |
| `octo-construction-kit-engine-mongodb` | `45320fd` | Make CrateQueryBuilder/Compiler/Exception internal to engine-mongodb |
| `octo-common-services` | `8519c15` | AB#3364: Remove legacy StreamData project (moved to engine-mongodb) |
| `octo-sdk` | `038deb3` | Emit Sd{CkType}DtoType GraphQL types in SDK source generator |
| `octo-asset-repo-services` | `23dea1e` | Fix null typed fields on per-type stream connections |
| `octo-mesh-adapter` | `3d60009` | AB#3364: Migrate mesh-adapter SaveInTimeSeriesNode to engine repository |
| `octo-frontend-libraries` | `3686967` | Regenerate octo-services types for stream/rt query symmetry |
| `octo-frontend-refinery-studio` | `d58113a` | Drop hard-coded CK model versions from query-label tests |
| `octo-tools` | `d6eeedf` | Plan: stream-data casing canonicalization |

**Wave-3 branches created in the four touched repos:** `octo-sdk`, `octo-construction-kit-engine-mongodb`, `octo-asset-repo-services`, `octo-tools`. The other five wave-2 repos keep their `feature/reimar/stream-rt-query-symmetry` branch untouched — wave 3 reads from them but does not modify them.

---

## File Structure

### Created
- `octo-construction-kit-engine-mongodb/tests/StreamData.UnitTests/StreamDataFieldResolverPathTests.cs` — unit tests for `ResolvePath`
- `octo-asset-repo-services/tests/AssetRepositoryServices.IntegrationTests/StreamData/StreamDataPathQueryTests.cs` — integration test for record-typed path traversal
- `octo-asset-repo-services/tests/AssetRepositoryIntegrationTestCkModel/ConstructionKit/records/coordinates.yaml` — record type for path test

### Modified
- `octo-sdk/src/Communication.Contracts/DataTransferObjects/StreamDataEntityDto.cs` — rename `TimeStamp` → `Timestamp`
- `octo-construction-kit-engine-mongodb/src/Runtime.Engine.MongoDb/StreamData/StreamDataFieldResolver.cs` — add `ResolvedPath` record + `ResolvePath` method
- `octo-construction-kit-engine-mongodb/src/Runtime.Engine.MongoDb/StreamData/CrateDbStreamDataRepository.cs` — `MapToStreamDataRow` keys by `CrateDbName`; aggregation path's `outputNameBySqlAlias` values become `CrateDbName`
- `octo-construction-kit-engine-mongodb/src/Runtime.Engine.MongoDb/StreamData/Constants.cs` — delete now-unused `*Alias` constants
- `octo-asset-repo-services/src/AssetRepositoryServices/GraphQL/Types/StreamDataQueryRowDtoType.cs` — `StreamDataQueryRowDto.ColumnNames` → `IReadOnlyList<ColumnNameMapping>`; cells resolver uses `.Canonical` for lookup, `.Wire` for `attributePath`
- `octo-asset-repo-services/src/AssetRepositoryServices/GraphQL/Types/StreamDataEntityGenericDtoType.cs` — cells resolver uses new mapping shape
- `octo-asset-repo-services/src/AssetRepositoryServices/GraphQL/StreamDataQuery.cs` — build mappings at call sites; simplify `ConvertToDataPointDto`
- `octo-asset-repo-services/src/AssetRepositoryServices/GraphQL/Types/StreamDataQueryDtoType.cs` — build mappings at call site
- `octo-asset-repo-services/src/AssetRepositoryServices/GraphQL/Types/StreamDataTransientQueryDtoType.cs` — build mappings at call site
- `octo-asset-repo-services/src/AssetRepositoryServices/GraphQL/Types/StreamDataEntityDtoType.cs` — remove the `Field<DateTimeGraphType>("timestamp")` override
- `octo-asset-repo-services/tests/AssetRepositoryServices.IntegrationTests/StreamData/StreamDataPerTypeConnectionTests.cs` — add invariant-pinning assertion
- `octo-asset-repo-services/tests/AssetRepositoryServices.IntegrationTests/StreamData/StreamDataSimpleQueryTests.cs` — add wire-format assertion on `cells.items[].attributePath`
- `octo-asset-repo-services/tests/AssetRepositoryIntegrationTestCkModel/ConstructionKit/types/meteringPoint.yaml` — add `Location: Coordinates` record attribute
- `octo-asset-repo-services/tests/AssetRepositoryIntegrationTestCkModel/ConstructionKit/attributes/meteringPoint.yaml` — declare the `Location` attribute

---

## Task 1: Introduce `ResolvedPath` + `ResolvePath` method (TDD, flat cases only)

Unit tests cover the cases that don't require a CK type graph: flat input, unknown segment, unsupported path tokens. Record-traversal paths are covered in Task 8's integration test.

**Files:**
- Modify: `octo-construction-kit-engine-mongodb/src/Runtime.Engine.MongoDb/StreamData/StreamDataFieldResolver.cs`
- Create: `octo-construction-kit-engine-mongodb/tests/StreamData.UnitTests/StreamDataFieldResolverPathTests.cs`

- [ ] **Step 1: Write failing unit tests**

Create `octo-construction-kit-engine-mongodb/tests/StreamData.UnitTests/StreamDataFieldResolverPathTests.cs`:

```csharp
using FluentAssertions;
using Meshmakers.Octo.Runtime.Engine.MongoDb.StreamData;

namespace Meshmakers.Octo.Runtime.Engine.MongoDb.StreamData.UnitTests;

public class StreamDataFieldResolverPathTests
{
    [Fact]
    public void ResolvePath_FlatAttribute_ReturnsCanonicalAndWire()
    {
        var resolver = new StreamDataFieldResolver(new[] { "Voltage" });

        var result = resolver.ResolvePath("Voltage", ckTypeGraph: null);

        result.Should().NotBeNull();
        result!.PascalCaseDotted.Should().Be("Voltage");
        result.CamelCaseDotted.Should().Be("voltage");
    }

    [Fact]
    public void ResolvePath_CaseInsensitiveInput_Normalizes()
    {
        var resolver = new StreamDataFieldResolver(new[] { "Voltage" });

        var result = resolver.ResolvePath("voltage", ckTypeGraph: null);

        result.Should().NotBeNull();
        result!.PascalCaseDotted.Should().Be("Voltage");
        result.CamelCaseDotted.Should().Be("voltage");
    }

    [Fact]
    public void ResolvePath_DefaultField_ResolvesViaFieldTable()
    {
        var resolver = new StreamDataFieldResolver();

        var result = resolver.ResolvePath("timestamp", ckTypeGraph: null);

        result.Should().NotBeNull();
        result!.PascalCaseDotted.Should().Be("Timestamp");
        result.CamelCaseDotted.Should().Be("timestamp");
    }

    [Fact]
    public void ResolvePath_UnknownFlatAttribute_ReturnsNull()
    {
        var resolver = new StreamDataFieldResolver(new[] { "Voltage" });

        var result = resolver.ResolvePath("NotAnAttribute", ckTypeGraph: null);

        result.Should().BeNull();
    }

    [Fact]
    public void ResolvePath_EmptyInput_ReturnsNull()
    {
        var resolver = new StreamDataFieldResolver();

        resolver.ResolvePath("", ckTypeGraph: null).Should().BeNull();
    }

    [Fact]
    public void ResolvePath_NavigationToken_Throws()
    {
        var resolver = new StreamDataFieldResolver(new[] { "Voltage" });

        var act = () => resolver.ResolvePath("Voltage->Owner", ckTypeGraph: null);

        act.Should().Throw<NotSupportedException>()
            .WithMessage("*navigation*");
    }

    [Fact]
    public void ResolvePath_ArrayIndexToken_Throws()
    {
        var resolver = new StreamDataFieldResolver(new[] { "Readings" });

        var act = () => resolver.ResolvePath("Readings[0]", ckTypeGraph: null);

        act.Should().Throw<NotSupportedException>()
            .WithMessage("*array*");
    }

    [Fact]
    public void ResolvePath_AssociationMetaToken_Throws()
    {
        var resolver = new StreamDataFieldResolver(new[] { "Voltage" });

        var act = () => resolver.ResolvePath("Voltage::AssocMeta", ckTypeGraph: null);

        act.Should().Throw<NotSupportedException>()
            .WithMessage("*association*");
    }

    [Fact]
    public void ResolvePath_DottedInputWithoutCkTypeGraph_ReturnsNull()
    {
        // Record traversal requires a ckTypeGraph; without one the resolver
        // cannot drill into record attributes. Integration tests cover the
        // positive record-path case end-to-end.
        var resolver = new StreamDataFieldResolver(new[] { "Voltage" });

        var result = resolver.ResolvePath("Issuer.CompanyName", ckTypeGraph: null);

        result.Should().BeNull();
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd /Users/reimar/dev/meshmakers/branches/main/octo-construction-kit-engine-mongodb
dotnet test tests/StreamData.UnitTests -c DebugL --filter "FullyQualifiedName~StreamDataFieldResolverPathTests"
```

Expected: build error — `ResolvePath` method doesn't exist.

- [ ] **Step 3: Add `ResolvedPath` record + `ResolvePath` method**

Edit `octo-construction-kit-engine-mongodb/src/Runtime.Engine.MongoDb/StreamData/StreamDataFieldResolver.cs`. Add at the top of the file, after the existing `ResolvedField` record:

```csharp
/// <summary>
/// Result of resolving a stream-data attribute path (flat or dotted).
/// </summary>
/// <param name="PascalCaseDotted">Canonical internal form: PascalCase segments joined by '.'</param>
/// <param name="CamelCaseDotted">Wire form: camelCase segments joined by '.'</param>
/// <param name="LeafCategory">Classification of the terminal segment</param>
public record ResolvedPath(
    string PascalCaseDotted,
    string CamelCaseDotted,
    StreamDataFieldCategory LeafCategory);
```

Add to `StreamDataFieldResolver` class, after `ResolveOrFallback`:

```csharp
/// <summary>
/// Resolves a possibly-dotted attribute path to its canonical internal (PascalCase)
/// and wire (camelCase) dotted forms. Flat input (no dots) is handled via the
/// existing <see cref="Resolve"/> lookup table. Dotted input currently requires
/// CK type graph context to drill into record-typed attributes; when
/// <paramref name="ckTypeGraph"/> is null, dotted input returns null.
///
/// Rejects navigation ('->'), array ('[n]'), and association-meta ('::') tokens —
/// those are not supported for stream-data and will throw.
/// </summary>
public ResolvedPath? ResolvePath(string input, object? ckTypeGraph)
{
    if (string.IsNullOrWhiteSpace(input)) return null;

    // Reject unsupported tokens explicitly — clearer errors than silent null.
    if (input.Contains("->"))
        throw new NotSupportedException(
            $"Stream-data paths do not support navigation ('->'): '{input}'");
    if (input.Contains('['))
        throw new NotSupportedException(
            $"Stream-data paths do not support array indexing ('[n]'): '{input}'");
    if (input.Contains("::"))
        throw new NotSupportedException(
            $"Stream-data paths do not support association-meta ('::'): '{input}'");

    // Flat case: delegate to existing Resolve.
    if (!input.Contains('.'))
    {
        var flat = Resolve(input);
        return flat is null
            ? null
            : new ResolvedPath(flat.CrateDbName, flat.GraphQlAlias, flat.Category);
    }

    // Dotted case: requires CK type graph to traverse record-typed segments.
    // Implementation fills in when Task 8's integration fixture provides the graph
    // shape; for now, without a graph we can't resolve record paths.
    if (ckTypeGraph is null) return null;

    // See Task 4 for the CK-graph-aware implementation. The unit tests above
    // deliberately pass ckTypeGraph: null; the positive record-path case is
    // covered by StreamDataPathQueryTests.
    throw new NotImplementedException(
        "Dotted path resolution with CK type graph is completed in Task 4 "
        + "when the caller signatures are rewired through.");
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
dotnet test tests/StreamData.UnitTests -c DebugL --filter "FullyQualifiedName~StreamDataFieldResolverPathTests"
```

Expected: all 9 tests pass.

- [ ] **Step 5: Run full unit test suite to ensure no regressions**

```bash
dotnet test tests/StreamData.UnitTests -c DebugL
```

Expected: all tests pass (new 9 + existing).

- [ ] **Step 6: Commit**

```bash
cd /Users/reimar/dev/meshmakers/branches/main/octo-construction-kit-engine-mongodb
git add src/Runtime.Engine.MongoDb/StreamData/StreamDataFieldResolver.cs \
        tests/StreamData.UnitTests/StreamDataFieldResolverPathTests.cs
git commit -m "$(cat <<'EOF'
Add ResolvedPath + flat ResolvePath on StreamDataFieldResolver

Introduces the single path-aware entry point that callers will route
through to obtain canonical PascalCase + wire camelCase forms. Flat
cases delegate to the existing Resolve; dotted cases stub with
NotImplementedException pending the CK-graph-aware implementation in
Task 4 when caller signatures are rewired.

Rejects unsupported tokens (->, [n], ::) explicitly — stream-data paths
don't support navigation, array indexing, or association-meta.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Rename `StreamDataEntityDto.TimeStamp` → `Timestamp` in octo-sdk

One-property rename. Triggers a rebuild cascade because several repos depend on this DTO via NuGet.

**Files:**
- Modify: `octo-sdk/src/Communication.Contracts/DataTransferObjects/StreamDataEntityDto.cs`

- [ ] **Step 1: Rename the property**

Edit `octo-sdk/src/Communication.Contracts/DataTransferObjects/StreamDataEntityDto.cs`. Find:

```csharp
public DateTime TimeStamp { get; set; }
```

Replace with:

```csharp
public DateTime Timestamp { get; set; }
```

Also search the file for any other `TimeStamp` references (e.g. in XML doc comments) and update to `Timestamp`.

- [ ] **Step 2: Find and update all usages in octo-sdk**

```bash
cd /Users/reimar/dev/meshmakers/branches/main/octo-sdk
grep -rn "\.TimeStamp\b\|TimeStamp =" src tests 2>/dev/null
```

For each hit, update `.TimeStamp` → `.Timestamp` and `TimeStamp =` → `Timestamp =`. Watch for xmldoc `<see cref="TimeStamp"/>` references.

- [ ] **Step 3: Build octo-sdk**

```bash
cd /Users/reimar/dev/meshmakers/branches/main/octo-sdk
dotnet build -c DebugL
```

Expected: build succeeds, 0 warnings, 0 errors.

- [ ] **Step 4: Run octo-sdk tests**

```bash
dotnet test -c DebugL
```

Expected: all tests pass.

- [ ] **Step 5: Publish updated NuGet via profile script**

```bash
pwsh -c ". /Users/reimar/dev/meshmakers/branches/main/octo-tools/modules/profile.ps1; Invoke-Build -repositoryPath /Users/reimar/dev/meshmakers/branches/main/octo-sdk -configuration DebugL"
```

Expected: builds and copies packages to `/Users/reimar/dev/meshmakers/branches/main/nuget/` so dependent repos pick up the new DTO.

- [ ] **Step 6: Commit**

```bash
cd /Users/reimar/dev/meshmakers/branches/main/octo-sdk
git add src/Communication.Contracts/DataTransferObjects/StreamDataEntityDto.cs
# Also stage any files touched in Step 2.
git status   # sanity check
git commit -m "$(cat <<'EOF'
Rename StreamDataEntityDto.TimeStamp → Timestamp

Aligns with StreamDataRow.Timestamp and DataPointDto.Timestamp (both
single word). Eliminates the explicit Field("timestamp") override on
the per-type GraphQL resolver that was working around GraphQL.NET's
auto-camelCase behaviour.

Part of the stream-data casing canonicalization
(docs/superpowers/specs/2026-04-12-stream-data-casing-canonicalization-design.md).

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Rebuild engine-mongodb + asset-repo against new octo-sdk

Sanity check that the DTO rename propagated. Non-code task; confirms we're building against the new contract.

**Files:** none.

- [ ] **Step 1: Rebuild engine-mongodb**

```bash
pwsh -c ". /Users/reimar/dev/meshmakers/branches/main/octo-tools/modules/profile.ps1; Invoke-Build -repositoryPath /Users/reimar/dev/meshmakers/branches/main/octo-construction-kit-engine-mongodb -configuration DebugL"
```

Expected: builds succeed. Any reference to the old `TimeStamp` spelling produces an error here — grep the error message and fix by renaming to `Timestamp`.

- [ ] **Step 2: Rebuild asset-repo**

```bash
pwsh -c ". /Users/reimar/dev/meshmakers/branches/main/octo-tools/modules/profile.ps1; Invoke-Build -repositoryPath /Users/reimar/dev/meshmakers/branches/main/octo-asset-repo-services -configuration DebugL"
```

Expected: builds succeed. One known site will still compile but produce the wrong wire name: `StreamDataEntityDtoType` currently has an explicit `Field<DateTimeGraphType>("timestamp").Resolve(ctx => ctx.Source.TimeStamp)` override — `ctx.Source.TimeStamp` becomes `ctx.Source.Timestamp`. Fix inline if the compiler flags it. If there are any other `.TimeStamp` references they should surface here — update them all to `.Timestamp`.

- [ ] **Step 3: Run asset-repo integration tests**

```bash
cd /Users/reimar/dev/meshmakers/branches/main/octo-asset-repo-services
dotnet test tests/AssetRepositoryServices.IntegrationTests -c DebugL --filter "FullyQualifiedName~StreamData" --no-build
```

Expected: all stream-data integration tests pass. The `Field<DateTimeGraphType>("timestamp")` override still exists (removed in Task 6); wire format is unchanged so tests stay green.

- [ ] **Step 4: Commit the cascading `.TimeStamp` → `.Timestamp` fixes if any**

Only if Step 2/3 required source edits in asset-repo or engine-mongodb:

```bash
# In each repo that needed fixes:
git add <changed-files>
git commit -m "$(cat <<'EOF'
Propagate StreamDataEntityDto.TimeStamp → Timestamp rename

Cascading fix from octo-sdk rename. No behaviour change.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)"
```

If no source edits were needed, skip this commit.

---

## Task 4: Add CK-graph-aware path resolution to `ResolvePath`

Completes the `NotImplementedException` branch from Task 1 with a real implementation. Adds a dependency on `ICkCacheService` (or just `CkTypeGraph` + record lookup) so the resolver can drill into record-typed attributes.

**Files:**
- Modify: `octo-construction-kit-engine-mongodb/src/Runtime.Engine.MongoDb/StreamData/StreamDataFieldResolver.cs`

- [ ] **Step 1: Change the `ResolvePath` signature to accept `CkTypeGraph`**

Replace the `object? ckTypeGraph` parameter with `CkTypeGraph? ckTypeGraph`. Add at top of file:

```csharp
using Meshmakers.Octo.ConstructionKit.Contracts.DependencyGraph;
```

Replace the method:

```csharp
public ResolvedPath? ResolvePath(string input, CkTypeGraph? ckTypeGraph)
{
    if (string.IsNullOrWhiteSpace(input)) return null;

    if (input.Contains("->"))
        throw new NotSupportedException(
            $"Stream-data paths do not support navigation ('->'): '{input}'");
    if (input.Contains('['))
        throw new NotSupportedException(
            $"Stream-data paths do not support array indexing ('[n]'): '{input}'");
    if (input.Contains("::"))
        throw new NotSupportedException(
            $"Stream-data paths do not support association-meta ('::'): '{input}'");

    if (!input.Contains('.'))
    {
        var flat = Resolve(input);
        return flat is null
            ? null
            : new ResolvedPath(flat.CrateDbName, flat.GraphQlAlias, flat.Category);
    }

    if (ckTypeGraph is null) return null;

    var segments = input.Split('.');
    if (segments.Length < 2) return null;  // defensive; already handled above

    // First segment: top-level attribute on the CK type.
    var firstFlat = Resolve(segments[0]);
    if (firstFlat is null) return null;

    if (!ckTypeGraph.AllAttributesByName.TryGetValue(firstFlat.CrateDbName, out var firstAttr))
        return null;

    var pascalSegments = new List<string> { firstFlat.CrateDbName };
    var wireSegments = new List<string> { firstFlat.GraphQlAlias };
    CkRecordGraph? currentRecord = null;

    // Drill into record-typed attributes for subsequent segments.
    if (firstAttr.ValueCkRecordId is not null)
    {
        // currentRecord resolved in-scope below for later segments.
    }
    else if (segments.Length > 1)
    {
        // Non-record first segment followed by dotted path — unresolvable.
        return null;
    }

    // (Record graph resolution requires ICkCacheService. The constructor change
    // below wires it in.)
    // For now: use the record graph passed via ckTypeGraph.AllAttributesByName's
    // value, which CkTypeAttributeGraph exposes transitively in ValueCkRecordId.
    // We inject ICkCacheService in the next step to avoid circular navigation.

    throw new NotImplementedException(
        "Requires ICkCacheService injection for record graph lookup. "
        + "See Step 2 below.");
}
```

- [ ] **Step 2: Inject `ICkCacheService` into `StreamDataFieldResolver`**

This changes the resolver's constructor. Rather than rewriting every caller, keep the parameterless and flat constructors; add an overload that accepts the cache service + tenant context:

```csharp
private readonly ICkCacheService? _ckCacheService;
private readonly string? _tenantId;

public StreamDataFieldResolver(
    IEnumerable<string> dataStreamAttributeNames,
    ICkCacheService? ckCacheService = null,
    string? tenantId = null)
{
    // existing initialization of _fields...
    foreach (var defaultField in Constants.DefaultStreamDataFields)
    {
        _fields[defaultField] = new ResolvedField(
            StreamDataFieldCategory.Default,
            defaultField,
            defaultField.ToCamelCase(),
            IsDataField: false);
    }

    foreach (var attrName in dataStreamAttributeNames)
    {
        if (!Constants.IsDefaultField(attrName))
        {
            _fields[attrName] = new ResolvedField(
                StreamDataFieldCategory.DataStream,
                attrName,
                attrName.ToCamelCase(),
                IsDataField: true);
        }
    }

    _ckCacheService = ckCacheService;
    _tenantId = tenantId;
}
```

Add `using Meshmakers.Octo.ConstructionKit.Contracts.Services;` at the top.

- [ ] **Step 3: Finish `ResolvePath` with real record traversal**

Replace the `throw new NotImplementedException(...)` block with:

```csharp
    if (ckTypeGraph is null) return null;

    var segments = input.Split('.');
    var firstFlat = Resolve(segments[0]);
    if (firstFlat is null) return null;
    if (!ckTypeGraph.AllAttributesByName.TryGetValue(firstFlat.CrateDbName, out var firstAttr))
        return null;

    var pascalSegments = new List<string> { firstFlat.CrateDbName };
    var wireSegments = new List<string> { firstFlat.GraphQlAlias };

    var currentRecordId = firstAttr.ValueCkRecordId;
    if (currentRecordId is null && segments.Length > 1)
        return null;  // non-record first segment followed by path

    for (var i = 1; i < segments.Length; i++)
    {
        if (_ckCacheService is null || _tenantId is null)
            return null;

        var recordGraph = _ckCacheService.GetRtCkRecord(_tenantId, currentRecordId!.ToRtCkId());
        if (recordGraph is null) return null;

        var segmentInput = segments[i];
        var matched = recordGraph.AllAttributesByName
            .FirstOrDefault(kv => string.Equals(kv.Key, segmentInput, StringComparison.OrdinalIgnoreCase));
        if (matched.Value is null) return null;

        pascalSegments.Add(matched.Key);
        wireSegments.Add(matched.Key.ToCamelCase());

        currentRecordId = matched.Value.ValueCkRecordId;
        if (currentRecordId is null && i < segments.Length - 1)
            return null;
    }

    return new ResolvedPath(
        string.Join('.', pascalSegments),
        string.Join('.', wireSegments),
        firstFlat.Category);
}
```

- [ ] **Step 4: Update unit test fixture — one test needs ckTypeGraph = null removed**

Re-read the test file. The existing `ResolvePath_DottedInputWithoutCkTypeGraph_ReturnsNull` test still passes (explicit null → null). Keep as-is. No other tests need updating since record traversal is covered by the integration test in Task 8.

- [ ] **Step 5: Run unit tests**

```bash
cd /Users/reimar/dev/meshmakers/branches/main/octo-construction-kit-engine-mongodb
dotnet build -c DebugL
dotnet test tests/StreamData.UnitTests -c DebugL --filter "FullyQualifiedName~StreamDataFieldResolverPathTests"
```

Expected: all 9 tests pass.

- [ ] **Step 6: Commit**

```bash
git add src/Runtime.Engine.MongoDb/StreamData/StreamDataFieldResolver.cs
git commit -m "$(cat <<'EOF'
Complete ResolvePath with CK-graph-aware record traversal

Drills into record-typed attribute segments via ICkCacheService. The
service is optional (default null) so flat-case callers stay unchanged.
Dotted paths on non-record attributes fail fast with null.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: Introduce `ColumnNameMapping` on `StreamDataQueryRowDto`; flip `MapToStreamDataRow` keys

This is the invariant flip. Batched into one commit because the two changes must ship atomically — otherwise the wire format breaks between them.

**Files:**
- Modify: `octo-asset-repo-services/src/AssetRepositoryServices/GraphQL/Types/StreamDataQueryRowDtoType.cs`
- Modify: `octo-asset-repo-services/src/AssetRepositoryServices/GraphQL/Types/StreamDataEntityGenericDtoType.cs`
- Modify: `octo-asset-repo-services/src/AssetRepositoryServices/GraphQL/StreamDataQuery.cs`
- Modify: `octo-asset-repo-services/src/AssetRepositoryServices/GraphQL/Types/StreamDataQueryDtoType.cs`
- Modify: `octo-asset-repo-services/src/AssetRepositoryServices/GraphQL/Types/StreamDataTransientQueryDtoType.cs`
- Modify: `octo-construction-kit-engine-mongodb/src/Runtime.Engine.MongoDb/StreamData/CrateDbStreamDataRepository.cs`

- [ ] **Step 1: Add `ColumnNameMapping` record and change `StreamDataQueryRowDto.ColumnNames` shape**

Edit `octo-asset-repo-services/src/AssetRepositoryServices/GraphQL/Types/StreamDataQueryRowDtoType.cs`.

Near the top of the file (before `StreamDataQueryRowDto`):

```csharp
/// <summary>
/// Column-name pair used by cells-based stream-data resolvers to bridge the
/// PascalCase-canonical internal form and the camelCase wire form.
/// </summary>
/// <param name="Canonical">PascalCase dotted name — used to look up values in StreamDataRow.Values / StreamDataQueryRowDto.Values.</param>
/// <param name="Wire">camelCase dotted name — emitted as attributePath on the GraphQL wire.</param>
public record ColumnNameMapping(string Canonical, string Wire);
```

Change the `ColumnNames` property type on `StreamDataQueryRowDto` from:

```csharp
public required IReadOnlyList<string> ColumnNames { get; init; }
```

to:

```csharp
public required IReadOnlyList<ColumnNameMapping> ColumnNames { get; init; }
```

- [ ] **Step 2: Update `FromStreamDataRow` signature**

In the same file, replace:

```csharp
public static StreamDataQueryRowDto FromStreamDataRow(
    StreamDataRow row,
    IReadOnlyList<string> columnNames)
{
    return new StreamDataQueryRowDto
    {
        RtId = row.RtId ?? OctoObjectId.Empty,
        CkTypeId = row.CkTypeId ?? new RtCkId<CkTypeId>(""),
        Timestamp = row.Timestamp,
        RtWellKnownName = row.RtWellKnownName,
        RtCreationDateTime = row.RtCreationDateTime,
        RtChangedDateTime = row.RtChangedDateTime,
        ColumnNames = columnNames,
        Values = row.Values
    };
}
```

with:

```csharp
public static StreamDataQueryRowDto FromStreamDataRow(
    StreamDataRow row,
    IReadOnlyList<ColumnNameMapping> columnNames)
{
    return new StreamDataQueryRowDto
    {
        RtId = row.RtId ?? OctoObjectId.Empty,
        CkTypeId = row.CkTypeId ?? new RtCkId<CkTypeId>(""),
        Timestamp = row.Timestamp,
        RtWellKnownName = row.RtWellKnownName,
        RtCreationDateTime = row.RtCreationDateTime,
        RtChangedDateTime = row.RtChangedDateTime,
        ColumnNames = columnNames,
        Values = row.Values
    };
}
```

- [ ] **Step 3: Update `ResolveCells` to use the mapping**

Replace the existing `ResolveCells`:

```csharp
private static object ResolveCells(IResolveConnectionContext<StreamDataQueryRowDto> context)
{
    var row = context.Source;
    var cells = row.ColumnNames.Select(mapping =>
    {
        row.Values.TryGetValue(mapping.Canonical, out var value);
        return new RtQueryCellDto
        {
            AttributePath = mapping.Wire,
            Value = value
        };
    });

    return ConnectionUtils.ToOctoConnection(cells, context);
}
```

- [ ] **Step 4: Update `StreamDataEntityGenericDtoType.ResolveCells`**

Edit `octo-asset-repo-services/src/AssetRepositoryServices/GraphQL/Types/StreamDataEntityGenericDtoType.cs`:

```csharp
private static object ResolveCells(IResolveConnectionContext<StreamDataQueryRowDto> ctx)
{
    var row = ctx.Source;
    var cells = row.ColumnNames.Select(mapping =>
    {
        row.Values.TryGetValue(mapping.Canonical, out var v);
        return new RtQueryCellDto
        {
            AttributePath = mapping.Wire,
            Value = v
        };
    });
    return ConnectionUtils.ToOctoConnection(cells, ctx);
}
```

- [ ] **Step 5: Flip `CrateDbStreamDataRepository.MapToStreamDataRow` to PascalCase keys**

Edit `octo-construction-kit-engine-mongodb/src/Runtime.Engine.MongoDb/StreamData/CrateDbStreamDataRepository.cs`.

Find `MapToStreamDataRow` (around line 528). Replace:

```csharp
private static StreamDataRow MapToStreamDataRow(DataPointDto dp, List<string> columnNames)
{
    var values = new Dictionary<string, object?>();
    foreach (var col in columnNames)
    {
        object? value = col switch
        {
            Constants.RtIdAlias => dp.RtId,
            Constants.CkTypeIdAlias => dp.CkTypeId,
            Constants.TimestampAlias => dp.Timestamp,
            Constants.RtWellKnownNameAlias => dp.RtWellKnownName,
            Constants.RtCreationDateTimeAlias => dp.RtCreationDateTime,
            Constants.RtChangedDateTimeAlias => dp.RtChangedDateTime,
            _ => dp.Attributes?.TryGetValue(col, out var v) == true ? v : null
        };
        values[col] = value;
    }

    return new StreamDataRow
    {
        RtId = dp.RtId,
        CkTypeId = dp.CkTypeId,
        Timestamp = dp.Timestamp,
        RtWellKnownName = dp.RtWellKnownName,
        RtCreationDateTime = dp.RtCreationDateTime,
        RtChangedDateTime = dp.RtChangedDateTime,
        Values = values
    };
}
```

with (note: `columnNames` parameter now contains PascalCase canonical names):

```csharp
private static StreamDataRow MapToStreamDataRow(DataPointDto dp, List<string> columnNames)
{
    var values = new Dictionary<string, object?>();
    foreach (var col in columnNames)
    {
        object? value = col switch
        {
            Constants.RtId => dp.RtId,
            Constants.CkTypeId => dp.CkTypeId,
            Constants.Timestamp => dp.Timestamp,
            Constants.RtWellKnownName => dp.RtWellKnownName,
            Constants.RtCreationDateTime => dp.RtCreationDateTime,
            Constants.RtChangedDateTime => dp.RtChangedDateTime,
            _ => dp.Attributes?.TryGetValue(col, out var v) == true ? v : null
        };
        values[col] = value;
    }

    return new StreamDataRow
    {
        RtId = dp.RtId,
        CkTypeId = dp.CkTypeId,
        Timestamp = dp.Timestamp,
        RtWellKnownName = dp.RtWellKnownName,
        RtCreationDateTime = dp.RtCreationDateTime,
        RtChangedDateTime = dp.RtChangedDateTime,
        Values = values
    };
}
```

- [ ] **Step 6: Flip the callers that build `columnNames` in engine-mongodb**

In the same file, `ExecuteQueryAsync` (around line 60–90). Find:

```csharp
var resolvedColumnNames = ResolveAndAddColumns(q, fieldResolver, options.Columns);
```

and a few lines later:

```csharp
var rows = data.Select(dp => MapToStreamDataRow(dp, resolvedColumnNames)).ToList();
```

Look at `ResolveAndAddColumns` (around line 306). Today it returns `resolved.GraphQlAlias` (camelCase). Change it to return `resolved.CrateDbName` (PascalCase):

```csharp
private static List<string> ResolveAndAddColumns(
    CrateQueryBuilder q,
    StreamDataFieldResolver fieldResolver,
    IReadOnlyList<string> columns)
{
    var resolvedColumnNames = new List<string>();
    foreach (var col in columns)
    {
        var resolved = fieldResolver.Resolve(col) ?? fieldResolver.ResolveOrFallback(col);
        // Canonical (PascalCase) is what StreamDataRow.Values is keyed by.
        resolvedColumnNames.Add(resolved.CrateDbName);
        if (resolved.IsDataField)
        {
            q.AddVariable(resolved.CrateDbName, resolved.CrateDbName, null, true);
        }
    }
    return resolvedColumnNames;
}
```

Note the second change: the SQL alias that `AddVariable` records also becomes `CrateDbName` instead of `GraphQlAlias`, so CrateDB returns column names already in PascalCase. This keeps `row.Values` keys in the canonical form.

- [ ] **Step 7: Flip the aggregation path's `outputNameBySqlAlias`**

Still in `CrateDbStreamDataRepository.cs`, `ExecuteAggregationQueryAsync` (around line 107–118). Replace:

```csharp
var aggFunc = MapAggregationFunction(col.Function);
var sqlAlias = $"{aggFunc}_{resolved.GraphQlAlias}";
q.AddAggregationVariable(resolved.CrateDbName, aggFunc, sqlAlias, resolved.IsDataField);

outputColumnNames.Add(resolved.GraphQlAlias);
outputNameBySqlAlias[sqlAlias] = resolved.GraphQlAlias;
```

with:

```csharp
var aggFunc = MapAggregationFunction(col.Function);
var sqlAlias = $"{aggFunc}_{resolved.CrateDbName}";
q.AddAggregationVariable(resolved.CrateDbName, aggFunc, sqlAlias, resolved.IsDataField);

outputColumnNames.Add(resolved.CrateDbName);
outputNameBySqlAlias[sqlAlias] = resolved.CrateDbName;
```

Repeat the same flip in `ExecuteGroupedAggregationQueryAsync` (around line 142–180) and `ExecuteDownsamplingQueryAsync` (around line 204–230) — every site that currently uses `resolved.GraphQlAlias` as a column name should use `resolved.CrateDbName`.

- [ ] **Step 8: Update `StreamDataQuery.cs` call sites to build `ColumnNameMapping` lists**

Edit `octo-asset-repo-services/src/AssetRepositoryServices/GraphQL/StreamDataQuery.cs`.

Find `ResolveStreamDataEntitiesAsync` (around line 127). Replace:

```csharp
var resolvedColumnNames = columnPaths
    .Select(c => fieldResolver.Resolve(c)!.GraphQlAlias)
    .ToList();

// ... later:
var rows = result.Rows
    .Select(r => StreamDataQueryRowDto.FromStreamDataRow(r, resolvedColumnNames))
    .ToList();
```

with:

```csharp
var columnMappings = columnPaths
    .Select(c =>
    {
        var r = fieldResolver.Resolve(c)!;
        return new ColumnNameMapping(r.CrateDbName, r.GraphQlAlias);
    })
    .ToList();

// ... later:
var rows = result.Rows
    .Select(r => StreamDataQueryRowDto.FromStreamDataRow(r, columnMappings))
    .ToList();
```

Also update `ResolveStreamDataEntitiesByTypeAsync` (around line 95):

```csharp
var resolvedColumnNames = columnPaths
    .Select(c => fieldResolver.Resolve(c)?.GraphQlAlias ?? c)
    .ToList();
```

→

```csharp
var resolvedColumnNames = columnPaths
    .Select(c => fieldResolver.Resolve(c)?.CrateDbName ?? c)
    .ToList();
```

(This is the per-type path which feeds `ConvertToDataPointDto` — it only needs the canonical form, no wire pairing.)

Add the `using` if missing: `using Meshmakers.Octo.Backend.AssetRepositoryServices.GraphQL.Types;`.

- [ ] **Step 9: Update `StreamDataQueryDtoType.cs` and `StreamDataTransientQueryDtoType.cs` similarly**

Grep for `GraphQlAlias` in these files:

```bash
cd /Users/reimar/dev/meshmakers/branches/main/octo-asset-repo-services
grep -n "GraphQlAlias" src/AssetRepositoryServices/GraphQL/Types/StreamDataQueryDtoType.cs \
                     src/AssetRepositoryServices/GraphQL/Types/StreamDataTransientQueryDtoType.cs
```

At each site that builds `resolvedColumnNames` as a `List<string>` of camelCase aliases, replace with a `List<ColumnNameMapping>` and feed it to `FromStreamDataRow`. The pattern is identical to Step 8.

- [ ] **Step 10: Build asset-repo and engine-mongodb**

```bash
pwsh -c ". /Users/reimar/dev/meshmakers/branches/main/octo-tools/modules/profile.ps1; Invoke-Build -repositoryPath /Users/reimar/dev/meshmakers/branches/main/octo-construction-kit-engine-mongodb -configuration DebugL"
pwsh -c ". /Users/reimar/dev/meshmakers/branches/main/octo-tools/modules/profile.ps1; Invoke-Build -repositoryPath /Users/reimar/dev/meshmakers/branches/main/octo-asset-repo-services -configuration DebugL"
```

Expected: both builds succeed. Compile errors here point at any missed call site — grep for `GraphQlAlias` and `resolvedColumnNames` in asset-repo, update remaining usages.

- [ ] **Step 11: Run integration tests**

```bash
cd /Users/reimar/dev/meshmakers/branches/main/octo-asset-repo-services
dotnet test tests/AssetRepositoryServices.IntegrationTests -c DebugL --filter "FullyQualifiedName~StreamData" --no-build
```

Expected: all stream-data integration tests pass. `cells.items[].attributePath` on the wire is still camelCase (now via explicit translation), so no test should break.

- [ ] **Step 12: Commit (engine-mongodb)**

```bash
cd /Users/reimar/dev/meshmakers/branches/main/octo-construction-kit-engine-mongodb
git add src/Runtime.Engine.MongoDb/StreamData/CrateDbStreamDataRepository.cs
git commit -m "$(cat <<'EOF'
Flip StreamDataRow.Values keys to PascalCase canonical form

MapToStreamDataRow and every aggregation path now key row.Values by
resolved.CrateDbName (PascalCase) instead of resolved.GraphQlAlias
(camelCase). Aligns stream-data storage with the PascalCase-canonical
convention already used by RtPathEvaluator and RtTypeWithAttributes.

Wire format unchanged — the asset-repo cells resolvers translate back
to camelCase at the output boundary via the new ColumnNameMapping
pairing (see octo-asset-repo-services commit).

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)"
```

- [ ] **Step 13: Commit (asset-repo)**

```bash
cd /Users/reimar/dev/meshmakers/branches/main/octo-asset-repo-services
git add src/AssetRepositoryServices/GraphQL/Types/StreamDataQueryRowDtoType.cs \
        src/AssetRepositoryServices/GraphQL/Types/StreamDataEntityGenericDtoType.cs \
        src/AssetRepositoryServices/GraphQL/StreamDataQuery.cs \
        src/AssetRepositoryServices/GraphQL/Types/StreamDataQueryDtoType.cs \
        src/AssetRepositoryServices/GraphQL/Types/StreamDataTransientQueryDtoType.cs
git commit -m "$(cat <<'EOF'
Pair canonical + wire column names via ColumnNameMapping

Cells-based resolvers (StreamDataQueryRowDtoType, StreamDataEntityGeneric
DtoType) now take a ColumnNameMapping(Canonical, Wire) list instead of a
flat string list. Canonical (PascalCase) keys Values lookup; Wire
(camelCase) is emitted as attributePath on the wire.

Paired with the engine-mongodb flip that keys row.Values by PascalCase
— the wire format stays camelCase, only the internal representation
changed.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: Simplify `ConvertToDataPointDto` and remove `timestamp` field override

Rekey hack and explicit field-name override both become redundant now that row.Values keys are PascalCase and `StreamDataEntityDto.Timestamp` (one word) auto-camelCases correctly.

**Files:**
- Modify: `octo-asset-repo-services/src/AssetRepositoryServices/GraphQL/StreamDataQuery.cs`
- Modify: `octo-asset-repo-services/src/AssetRepositoryServices/GraphQL/Types/StreamDataEntityDtoType.cs`

- [ ] **Step 1: Simplify `ConvertToDataPointDto`**

Edit `StreamDataQuery.cs`. Find `ConvertToDataPointDto` (around line 293). Replace:

```csharp
private static DataPointDto ConvertToDataPointDto(StreamDataRow row, StreamDataFieldResolver fieldResolver)
{
    // Adapter: StreamDataEntityDtoType.CreateStreamDataEntityDto takes DataPointDto.
    // row.Values is keyed by GraphQlAlias (camelCase, e.g. "state"); DataPointDto.Attributes
    // must be keyed by the canonical PascalCase CK AttributeName ("State") because
    // RtTypeWithAttributes.GetAttributeValueOrDefault does a case-sensitive lookup and the
    // per-type resolver (ResolveAttributeValue in StreamDataEntityDtoType) passes in the
    // PascalCase name. Without this rekey, typed enum/attribute fields come back null.
    var attributes = new Dictionary<string, object?>();
    foreach (var (key, value) in row.Values)
    {
        var resolved = fieldResolver.Resolve(key);
        if (resolved is { Category: StreamDataFieldCategory.DataStream })
        {
            attributes[resolved.CrateDbName] = value;
        }
        // Default fields (RtId, Timestamp, ...) land as top-level DataPointDto properties
        // below, so we skip them in the Attributes bag.
    }

    return new DataPointDto(attributes)
    {
        RtId = row.RtId ?? OctoObjectId.Empty,
        CkTypeId = row.CkTypeId ?? throw new InvalidOperationException("CkTypeId missing on StreamDataRow"),
        Timestamp = row.Timestamp ?? default,
        RtWellKnownName = row.RtWellKnownName,
        RtCreationDateTime = row.RtCreationDateTime ?? default,
        RtChangedDateTime = row.RtChangedDateTime ?? default
    };
}
```

with:

```csharp
private static DataPointDto ConvertToDataPointDto(StreamDataRow row)
{
    // row.Values is keyed by PascalCase dotted canonical form — the same form
    // RtTypeWithAttributes.GetAttributeValueOrDefault expects. Direct copy.
    return new DataPointDto(new Dictionary<string, object?>(row.Values))
    {
        RtId = row.RtId ?? OctoObjectId.Empty,
        CkTypeId = row.CkTypeId ?? throw new InvalidOperationException("CkTypeId missing on StreamDataRow"),
        Timestamp = row.Timestamp ?? default,
        RtWellKnownName = row.RtWellKnownName,
        RtCreationDateTime = row.RtCreationDateTime ?? default,
        RtChangedDateTime = row.RtChangedDateTime ?? default
    };
}
```

- [ ] **Step 2: Update `ResolveStreamDataEntitiesByTypeAsync` to pass only `row` (no fieldResolver)**

Still in `StreamDataQuery.cs`. Around line 113:

```csharp
var rows = result.Rows
    .Select(row => StreamDataEntityDtoType.CreateStreamDataEntityDto(
        ConvertToDataPointDto(row, fieldResolver)))
    .ToList();
```

→

```csharp
var rows = result.Rows
    .Select(row => StreamDataEntityDtoType.CreateStreamDataEntityDto(
        ConvertToDataPointDto(row)))
    .ToList();
```

- [ ] **Step 3: Remove the `timestamp` field override**

Edit `octo-asset-repo-services/src/AssetRepositoryServices/GraphQL/Types/StreamDataEntityDtoType.cs`. Find (around line 64–68):

```csharp
// Expose as `timestamp` (single word) so the per-type connection matches the generic
// `streamDataEntities` and `streamDataQuery` row shapes. The underlying DTO property is
// `TimeStamp` (two words), which would otherwise camelCase to `timeStamp` — a drift from
// the rest of the stream-data surface. See schema tests in StreamDataBetweenFilterTests.
Field<DateTimeGraphType>("timestamp").Resolve(ctx => ctx.Source.TimeStamp);
```

Replace with:

```csharp
Field(d => d.Timestamp, typeof(DateTimeGraphType));
```

(The DTO property is now `Timestamp` — one word — so GraphQL.NET auto-camelCases to `timestamp` correctly.)

- [ ] **Step 4: Build + run integration tests**

```bash
cd /Users/reimar/dev/meshmakers/branches/main/octo-asset-repo-services
dotnet build -c DebugL
dotnet test tests/AssetRepositoryServices.IntegrationTests -c DebugL --filter "FullyQualifiedName~StreamData" --no-build
```

Expected: all stream-data integration tests pass. Wire format unchanged.

- [ ] **Step 5: Commit**

```bash
git add src/AssetRepositoryServices/GraphQL/StreamDataQuery.cs \
        src/AssetRepositoryServices/GraphQL/Types/StreamDataEntityDtoType.cs
git commit -m "$(cat <<'EOF'
Remove now-redundant rekey and timestamp field override

Two leftovers from earlier workarounds:
- ConvertToDataPointDto's camelCase→PascalCase rekey (commit 23dea1e)
  is redundant now that row.Values keys are PascalCase-canonical.
- The Field<DateTimeGraphType>("timestamp") override (commit c00deac)
  is redundant now that StreamDataEntityDto.Timestamp (one word)
  auto-camelCases correctly.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 7: Delete unused `*Alias` constants in `Constants.cs`

After Tasks 5–6, `Constants.RtIdAlias`, `TimestampAlias`, etc. are only used by `StreamDataFieldResolver` itself to seed its mapping table. Delete them (or scope internal) to prevent accidental reuse.

**Files:**
- Modify: `octo-construction-kit-engine-mongodb/src/Runtime.Engine.MongoDb/StreamData/Constants.cs`
- Modify: `octo-construction-kit-engine-mongodb/src/Runtime.Engine.MongoDb/StreamData/StreamDataFieldResolver.cs`

- [ ] **Step 1: Find all remaining usages**

```bash
cd /Users/reimar/dev/meshmakers/branches/main
grep -rn "RtIdAlias\|TimestampAlias\|CkTypeIdAlias\|RtWellKnownNameAlias\|RtCreationDateTimeAlias\|RtChangedDateTimeAlias" \
     octo-construction-kit-engine-mongodb/src octo-asset-repo-services/src
```

Expected: only `StreamDataFieldResolver.cs` references them, in the default-field initialization loop. If any asset-repo references remain, they're leftover from Task 5 and need flipping first — fix them inline before continuing.

- [ ] **Step 2: Inline the `*Alias` values in `StreamDataFieldResolver`**

The default-field seeding loop already uses `.ToCamelCase()` on each PascalCase name, so the `*Alias` constants are redundant:

```csharp
foreach (var defaultField in Constants.DefaultStreamDataFields)
{
    _fields[defaultField] = new ResolvedField(
        StreamDataFieldCategory.Default,
        defaultField,
        defaultField.ToCamelCase(),  // already does the right thing
        IsDataField: false);
}
```

No change needed here. Confirm by reading the file.

- [ ] **Step 3: Delete the `*Alias` constants**

Edit `octo-construction-kit-engine-mongodb/src/Runtime.Engine.MongoDb/StreamData/Constants.cs`. Delete lines 44–59 (the six `*Alias` constants and their xmldoc). Leave `DefaultStreamDataFields`, `IsDefaultField`, `GetDefaultFieldName`, `DateTimeFormat`, and `DefaultConnectionCacheDuration` in place.

- [ ] **Step 4: Build engine-mongodb**

```bash
cd /Users/reimar/dev/meshmakers/branches/main/octo-construction-kit-engine-mongodb
dotnet build -c DebugL
```

Expected: success. Any leftover callers surface as compile errors.

- [ ] **Step 5: Run unit tests**

```bash
dotnet test tests/StreamData.UnitTests -c DebugL
```

Expected: all pass.

- [ ] **Step 6: Commit**

```bash
git add src/Runtime.Engine.MongoDb/StreamData/Constants.cs
git commit -m "$(cat <<'EOF'
Delete unused *Alias constants

After the PascalCase-canonical flip, the camelCase *Alias constants in
Constants.cs are only referenced by StreamDataFieldResolver's default
-field initialization, which computes the camelCase name via
.ToCamelCase() directly. The constants are dead code and would only
tempt future devs to bypass the resolver.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 8: Integration test — path traversal through a record-typed attribute

Adds the end-to-end path test that the unit tests explicitly skipped. Requires extending the `MeteringPoint` test CK model with a record-typed attribute.

**Files:**
- Create: `octo-asset-repo-services/tests/AssetRepositoryIntegrationTestCkModel/ConstructionKit/records/coordinates.yaml`
- Modify: `octo-asset-repo-services/tests/AssetRepositoryIntegrationTestCkModel/ConstructionKit/attributes/meteringPoint.yaml`
- Modify: `octo-asset-repo-services/tests/AssetRepositoryIntegrationTestCkModel/ConstructionKit/types/meteringPoint.yaml`
- Create: `octo-asset-repo-services/tests/AssetRepositoryServices.IntegrationTests/StreamData/StreamDataPathQueryTests.cs`
- Modify: `octo-asset-repo-services/tests/AssetRepositoryServices.IntegrationTests/Fixtures/StreamDataFixture.cs` — extend test data to populate Location

- [ ] **Step 1: Add a `Coordinates` record type**

Create `octo-asset-repo-services/tests/AssetRepositoryIntegrationTestCkModel/ConstructionKit/records/coordinates.yaml`:

```yaml
$schema: https://schemas.meshmakers.cloud/construction-kit-elements.schema.json
records:
- recordId: Coordinates
  attributes:
  - id: ${this}/Latitude
    name: Latitude
  - id: ${this}/Longitude
    name: Longitude
```

- [ ] **Step 2: Declare the Latitude/Longitude attribute scalars**

Edit `octo-asset-repo-services/tests/AssetRepositoryIntegrationTestCkModel/ConstructionKit/attributes/meteringPoint.yaml`. Inspect its current shape:

```bash
cat /Users/reimar/dev/meshmakers/branches/main/octo-asset-repo-services/tests/AssetRepositoryIntegrationTestCkModel/ConstructionKit/attributes/meteringPoint.yaml
```

Add these two entries in the `attributes:` list (assuming the file uses the Double value type for other scalars — mirror the shape of `Voltage`):

```yaml
  - attributeId: ${this}/Latitude
    valueType: Double
  - attributeId: ${this}/Longitude
    valueType: Double
  - attributeId: ${this}/Location
    valueType: Record
    ckRecordId: ${this}/Coordinates
```

(Exact YAML shape may differ — use the existing `Voltage` attribute as the template; `valueType: Record` + `ckRecordId` is how record-typed attributes are declared in other CK YAML files. Grep for `valueType: Record` elsewhere in the test CK model and mirror.)

- [ ] **Step 3: Add `Location` attribute ref to the `MeteringPoint` type**

Edit `octo-asset-repo-services/tests/AssetRepositoryIntegrationTestCkModel/ConstructionKit/types/meteringPoint.yaml`. Append below the existing stream-data attributes:

```yaml
  - id: ${this}/Location
    name: Location
    isOptional: true
    isDataStream: true
```

Note the `isDataStream: true` flag so the field resolver registers it.

- [ ] **Step 4: Extend fixture test data to populate Location**

Edit `octo-asset-repo-services/tests/AssetRepositoryServices.IntegrationTests/Fixtures/StreamDataFixture.cs`. Find `InsertTestDataPoints` (around line 162):

```csharp
var attributes = new Dictionary<string, object?>
{
    ["Voltage"] = voltage,
    ["Current"] = current
};
```

Replace with:

```csharp
var attributes = new Dictionary<string, object?>
{
    ["Voltage"] = voltage,
    ["Current"] = current,
    ["Location.Latitude"] = 48.2 + (i * 0.01),
    ["Location.Longitude"] = 16.3 + (i * 0.01)
};
```

(CrateDB stores nested record attributes as flattened `Record.Field` columns. The fixture's `InsertDataAsync` must handle the dotted key — if it doesn't, surface the error in Step 6 and either fix `InsertDataAsync` or use separate flat attributes for this test. Verify by grepping `CrateDatabaseClient.InsertDataAsync` before assuming.)

- [ ] **Step 5: Write the integration test**

Create `octo-asset-repo-services/tests/AssetRepositoryServices.IntegrationTests/StreamData/StreamDataPathQueryTests.cs`:

```csharp
using System.Text.Json;
using FluentAssertions;
using Meshmakers.Octo.Backend.AssetRepositoryServices.IntegrationTests.Fixtures;
using Xunit;

namespace Meshmakers.Octo.Backend.AssetRepositoryServices.IntegrationTests.StreamData;

/// <summary>
/// Integration tests for dotted-path attribute traversal through record-typed
/// attributes (e.g. `location.latitude` → `Location.Latitude`).
/// </summary>
[Collection("Sequential")]
public class StreamDataPathQueryTests(StreamDataFixture fixture, ITestOutputHelper output)
    : IClassFixture<StreamDataFixture>
{
    [Fact]
    public async Task PerTypeConnection_RecordPathResolves()
    {
        fixture.OutputHelper = output;

        const string query = """
            {
                streamData {
                    assetRepositoryIntegrationTestMeteringPoint(first: 3) {
                        totalCount
                        items {
                            rtId
                            timestamp
                            location {
                                latitude
                                longitude
                            }
                        }
                    }
                }
            }
            """;

        var result = await fixture.ExecuteGraphQlAsync(query);
        output.WriteLine(fixture.SerializeGraphQl(result));

        result.Errors.Should().BeNullOrEmpty();

        var items = GetItems(result);
        items.Should().HaveCount(3);

        foreach (var item in items)
        {
            var location = item.GetProperty("location");
            location.ValueKind.Should().NotBe(JsonValueKind.Null);
            location.GetProperty("latitude").ValueKind.Should().Be(JsonValueKind.Number);
            location.GetProperty("longitude").ValueKind.Should().Be(JsonValueKind.Number);
        }
    }

    [Fact]
    public async Task TransientSimple_SelectsRecordPath_EmitsCamelCaseAttributePath()
    {
        fixture.OutputHelper = output;

        const string query = """
            {
                streamData {
                    transientStreamDataQuery {
                        simple(
                            ckId: "AssetRepositoryIntegrationTest/MeteringPoint"
                            columnPaths: ["location.latitude"]
                            first: 3
                        ) {
                            items {
                                rows(first: 3) {
                                    items {
                                        cells(first: 5) {
                                            items {
                                                attributePath
                                                value
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            """;

        var result = await fixture.ExecuteGraphQlAsync(query);
        output.WriteLine(fixture.SerializeGraphQl(result));

        result.Errors.Should().BeNullOrEmpty();

        // Every emitted cell's attributePath must be camelCase dotted.
        var cells = GetFirstRowCells(result);
        cells.Should().NotBeEmpty();
        cells.Single().GetProperty("attributePath").GetString()
            .Should().Be("location.latitude",
                "wire format is camelCase dotted paths");
    }

    private JsonElement GetItems(global::GraphQL.ExecutionResult result)
    {
        var json = fixture.SerializeGraphQl(result);
        var doc = JsonDocument.Parse(json);
        return doc.RootElement
            .GetProperty("data")
            .GetProperty("streamData")
            .GetProperty("assetRepositoryIntegrationTestMeteringPoint")
            .GetProperty("items");
    }

    private List<JsonElement> GetFirstRowCells(global::GraphQL.ExecutionResult result)
    {
        var json = fixture.SerializeGraphQl(result);
        var doc = JsonDocument.Parse(json);
        return doc.RootElement
            .GetProperty("data")
            .GetProperty("streamData")
            .GetProperty("transientStreamDataQuery")
            .GetProperty("simple")
            .GetProperty("items").EnumerateArray().First()
            .GetProperty("rows")
            .GetProperty("items").EnumerateArray().First()
            .GetProperty("cells")
            .GetProperty("items").EnumerateArray().ToList();
    }
}
```

- [ ] **Step 6: Rebuild CK model, asset-repo, run the new tests**

```bash
cd /Users/reimar/dev/meshmakers/branches/main/octo-asset-repo-services
pwsh -c ". /Users/reimar/dev/meshmakers/branches/main/octo-tools/modules/profile.ps1; Invoke-Build -repositoryPath . -configuration DebugL"
dotnet test tests/AssetRepositoryServices.IntegrationTests -c DebugL --filter "FullyQualifiedName~StreamDataPathQueryTests" --no-build
```

Expected: both tests pass.

If `PerTypeConnection_RecordPathResolves` fails with "field `location` not found on …MeteringPoint", the CK model YAML didn't register the record attribute — re-inspect `attributes/meteringPoint.yaml` and `types/meteringPoint.yaml` against how `Voltage` (which is known-working) is declared.

If `TransientSimple_SelectsRecordPath_EmitsCamelCaseAttributePath` fails with attributePath `"Location.Latitude"`, the cells translation in Task 5 missed a site — grep for any remaining `Wire = mapping.Canonical` typo.

If test data insertion fails with "unknown column `Location.Latitude`", CrateDB requires an OBJECT-typed column declaration. Either extend `StreamDataFixture.CreateTable` to include the nested schema, or simplify the test data to use flat attributes (e.g. add `Altitude: Double` directly on MeteringPoint) and adjust the test query. Flag this to the user before widening scope.

- [ ] **Step 7: Commit**

```bash
git add tests/AssetRepositoryIntegrationTestCkModel/ConstructionKit/records/coordinates.yaml \
        tests/AssetRepositoryIntegrationTestCkModel/ConstructionKit/attributes/meteringPoint.yaml \
        tests/AssetRepositoryIntegrationTestCkModel/ConstructionKit/types/meteringPoint.yaml \
        tests/AssetRepositoryServices.IntegrationTests/Fixtures/StreamDataFixture.cs \
        tests/AssetRepositoryServices.IntegrationTests/StreamData/StreamDataPathQueryTests.cs
git commit -m "$(cat <<'EOF'
Integration test: record-typed path traversal in stream-data queries

Adds a Coordinates record type and Location: Coordinates attribute to
the MeteringPoint test fixture. Verifies:

1. Per-type connection emits nested typed location { latitude, longitude }.
2. Transient cells-based query emits camelCase dotted attributePath
   (location.latitude) on the wire — pins the output-boundary translation.

End-to-end coverage for the PascalCase-canonical + camelCase-wire
invariant for dotted paths.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 9: Invariant-pinning tests

Two small additions to catch future regressions of the canonical-form rule.

**Files:**
- Modify: `octo-asset-repo-services/tests/AssetRepositoryServices.IntegrationTests/StreamData/StreamDataPerTypeConnectionTests.cs`
- Modify: `octo-asset-repo-services/tests/AssetRepositoryServices.IntegrationTests/StreamData/StreamDataSimpleQueryTests.cs`

- [ ] **Step 1: Add `cells.items[].attributePath` wire-format assertion to an existing test**

Edit `StreamDataSimpleQueryTests.cs`. Find the `TransientSimpleQuery_ReturnsAllDataPoints` test (around line 18). Its query already selects `cells.items.attributePath`. Add an assertion after `items.Should().HaveCount(fixture.TestDataPointCount);`:

```csharp
// Wire-format pin: attributePath values are camelCase dotted.
foreach (var item in items.Take(3))
{
    var cells = item.GetProperty("cells").GetProperty("items").EnumerateArray();
    foreach (var cell in cells)
    {
        var attrPath = cell.GetProperty("attributePath").GetString();
        attrPath.Should().NotBeNullOrEmpty();
        attrPath!.Should().MatchRegex("^[a-z][a-zA-Z0-9.]*$",
            "attributePath must be camelCase dotted on the GraphQL wire");
    }
}
```

- [ ] **Step 2: Add row-values invariant test to `StreamDataPerTypeConnectionTests`**

For this test we need to inspect the internal `StreamDataRow.Values` directly, which isn't exposed through GraphQL. Add a helper on `StreamDataFixture` that exposes the repository:

Edit `StreamDataFixture.cs`. Add at the bottom of the public API (before `DisposeServicesAsync`):

```csharp
/// <summary>
/// Executes a stream-data query directly against the engine repository (bypassing GraphQL),
/// used by invariant-pinning tests that inspect StreamDataRow.Values keys.
/// </summary>
public async Task<IReadOnlyList<Meshmakers.Octo.Runtime.Contracts.StreamData.StreamDataRow>> ExecuteRepoQueryDirectAsync(
    string ckTypeId,
    IReadOnlyList<string> columnPaths)
{
    var ckId = new Meshmakers.Octo.ConstructionKit.Contracts.RtCkId<Meshmakers.Octo.ConstructionKit.Contracts.CkTypeId>(ckTypeId);
    var options = Meshmakers.Octo.Runtime.Contracts.StreamData.StreamDataQueryOptions.Create()
        .WithCkTypeId(ckId)
        .WithColumns(columnPaths.ToList())
        .WithPagination(0, 10);

    var tenantContext = await GetSystemContext().FindTenantContextAsync(GetSystemContext().TenantId);
    var repo = tenantContext.GetStreamDataRepository()
        ?? throw new InvalidOperationException("stream-data not enabled");
    var result = await repo.ExecuteQueryAsync(options);
    return result.Rows;
}
```

Then edit `StreamDataPerTypeConnectionTests.cs` and add:

```csharp
[Fact]
public async Task PerTypeConnection_RowValuesAreKeyedInPascalCase()
{
    fixture.OutputHelper = output;

    var rows = await fixture.ExecuteRepoQueryDirectAsync(
        fixture.TestCkTypeId,
        new[] { "Voltage", "Current" });

    rows.Should().NotBeEmpty();
    foreach (var row in rows)
    {
        foreach (var key in row.Values.Keys)
        {
            key.Should().MatchRegex("^[A-Z][a-zA-Z0-9.]*$",
                "internal stream-data row keys are PascalCase canonical — " +
                "camelCase keys would be a regression of the casing invariant");
        }
    }
}
```

- [ ] **Step 3: Run both tests**

```bash
cd /Users/reimar/dev/meshmakers/branches/main/octo-asset-repo-services
dotnet test tests/AssetRepositoryServices.IntegrationTests -c DebugL \
  --filter "FullyQualifiedName~PerTypeConnection_RowValuesAreKeyedInPascalCase|FullyQualifiedName~TransientSimpleQuery_ReturnsAllDataPoints"
```

Expected: both pass.

- [ ] **Step 4: Run full stream-data integration suite**

```bash
dotnet test tests/AssetRepositoryServices.IntegrationTests -c DebugL --filter "FullyQualifiedName~StreamData" --no-build
```

Expected: all green.

- [ ] **Step 5: Commit**

```bash
git add tests/AssetRepositoryServices.IntegrationTests/Fixtures/StreamDataFixture.cs \
        tests/AssetRepositoryServices.IntegrationTests/StreamData/StreamDataPerTypeConnectionTests.cs \
        tests/AssetRepositoryServices.IntegrationTests/StreamData/StreamDataSimpleQueryTests.cs
git commit -m "$(cat <<'EOF'
Invariant pins for stream-data casing convention

Two regression guards for the PascalCase-canonical + camelCase-wire rule:

1. PerTypeConnection_RowValuesAreKeyedInPascalCase — executes a query
   directly against the engine repository, asserts every key in
   StreamDataRow.Values starts with an uppercase letter. Catches any
   future drift at the engine layer.
2. TransientSimpleQuery_ReturnsAllDataPoints (extended) — asserts
   cells.items[].attributePath matches ^[a-z][a-zA-Z0-9.]*$. Catches
   any future drift at the output-translation boundary.

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 10: Cross-repo build sanity check

After all local changes, confirm every touched repo builds clean against the others on `feature/reimar/stream-rt-query-symmetry`.

**Files:** none.

- [ ] **Step 1: Full dependency-order rebuild**

```bash
pwsh -c ". /Users/reimar/dev/meshmakers/branches/main/octo-tools/modules/profile.ps1; Invoke-BuildAll -configuration DebugL"
```

Expected: every repo builds, no errors.

If any repo fails, the error points at a missed migration — grep the error symbol and check whether Task 5/6/7 missed a site.

- [ ] **Step 2: Run full integration test suite**

```bash
cd /Users/reimar/dev/meshmakers/branches/main/octo-asset-repo-services
dotnet test -c DebugL --filter "FullyQualifiedName!~SystemTests" --no-build
```

Expected: all tests pass. System tests are skipped because they need a running stack.

- [ ] **Step 3: No commit (build-check only)**

Nothing to commit — this task verifies the whole change set.

---

## Self-review (done inline)

**Spec coverage:**
- Option 2 architecture rule → Tasks 1, 4, 5, 6 (ResolvePath, keys flip, rekey removal, override removal).
- Components "Modified" list → Tasks 2, 5, 6, 7 map 1-to-1.
- Components "Added" tests → Tasks 1, 8, 9.
- Data flow invariant → Tasks 5, 9 together pin both ends.
- Edge cases (aggregation aliases, default fields, unsupported tokens) → Task 5 step 7, Task 7, Task 1 tests.
- Non-goals respected: no RtPathEvaluator touches, no typed ResolvedField cascade, no navigation/array support, no wire-format changes.

**Placeholder scan:** grep-checked the plan for TBD / TODO / "fill in" — none outside spec-style references to Task numbers. All code blocks are concrete.

**Type consistency:** `ResolvedPath { PascalCaseDotted, CamelCaseDotted, LeafCategory }` used consistently across Tasks 1, 4. `ColumnNameMapping(Canonical, Wire)` used in Tasks 5, 8, 9. `StreamDataFieldResolver` constructor overload signature documented in Task 4 step 2 and compatible with existing callers.

**Known risk:** Task 8 step 4 (CrateDB nested-record storage) has a soft path — I've flagged it for the implementer to stop and ask rather than force the fix if the fixture's insert path doesn't already handle dotted keys.
