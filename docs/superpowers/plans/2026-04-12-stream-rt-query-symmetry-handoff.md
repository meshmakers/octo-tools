# Stream/RT Query Symmetry Refactor — Handoff to Next Agent

You are taking over a multi-repo refactor mid-execution. Phases 0–6 are complete and committed. You will execute **Phase 7 only** (frontend migration) and then close out.

## User context (read first, hard rules)

1. **Never wipe any database.** No `Invoke-MongoDeleteOctoMesh`, no `DROP DATABASE`, no container recreation that loses data. The user handles local cleanup manually.
2. **Never start destructive git operations** (force push, reset --hard on shared branches, branch -D without confirmation).
3. **Feature branches are sacred** — all work lives on `feature/reimar/stream-rt-query-symmetry` across all 8 repos. Don't merge to main. Don't rebase onto main.
4. **Apollo codegen protocol:** the FIRST `npm run codegen` must be triggered by the user (to confirm the backend is running and auth is set up). After that first run is confirmed, you can invoke `npm run codegen` directly for subsequent regenerations.
5. **Always ask the user** via `AskUserQuestion` for substantive decisions, not plain-text questions.
6. **Don't run sed/grep/cat/head/tail as bash** — use the Grep, Glob, Read tools.
7. Use `git -C <repo>` for git commands — this is a monorepo-of-repos workspace.

## Where we are

**Spec:** `/Users/reimar/dev/meshmakers/branches/main/octo-tools/docs/superpowers/specs/2026-04-12-stream-rt-query-symmetry-design.md`
**Plan:** `/Users/reimar/dev/meshmakers/branches/main/octo-tools/docs/superpowers/plans/2026-04-12-stream-rt-query-symmetry.md`

All 8 affected repos on branch `feature/reimar/stream-rt-query-symmetry`:
- `octo-construction-kit-engine`
- `octo-construction-kit-engine-mongodb`
- `octo-common-services`
- `octo-asset-repo-services`
- `octo-mesh-adapter`
- `octo-sdk`
- `octo-frontend-refinery-studio`
- `octo-tools` (plan/spec docs)

## Phases completed

| Phase | Status | Headline |
|---|---|---|
| 0 Branching | ✅ | Branches created from prior feature branch |
| 1 Shared contracts | ✅ | `AggregationFunction` enum + `AggregationColumn` record in Runtime.Contracts; 6 stream-specific duplicate types deleted; CrateDB operator mapper with Between/In/NotIn/IsNull/IsNotNull |
| 2 CK model rename | ✅ | System CK model 2.0.8 → 2.0.9; abstract `StreamDataQuery` base; `SimpleSdQuery`/`AggregationSdQuery`/`GroupingAggregationSdQuery`/`DownsamplingSdQuery` |
| 3 SdEntity + source generators | ✅ | `SdEntity` base; engine CK generator emits `Sd{CkType}`; SDK generator emits `Sd{CkType}DtoType`; `SdEntityHydrator` with 5 unit tests |
| 4 Descriptor pattern | ✅ | `StreamDataQueryDto`/Type + `StreamDataTransientQuery` namespace + `StreamDataTransientQueryDto`/Type; `StreamDataVariantExecutor`; 8 old root resolvers deleted; `.Rows` + `.Aggregations` sub-connections |
| 5 Per-type + generic | ✅ | Per-type resolver migrated to options+repo; new generic `streamDataEntities(ckId)`; 4 helpers deleted; zero `CrateQueryBuilder` refs in asset-repo |
| 6 Engine internals | ✅ | `CrateQueryBuilder`/`CrateQueryCompiler`/`QueryBuilderException` → internal; `InternalsVisibleTo` for tests |
| 7 Frontend migration | ⏳ **Next — your job** | — |

## Plan deviations accumulated (all documented in commit messages)

1. **Task 1.1:** Introduced `AggregationFunction` enum in `Runtime.Contracts/Repositories/Query/` instead of reusing CK-generated `AggregationTypes`. Reason: `Runtime.Contracts` can't reference `SystemCkModel` — layering violation.
2. **Task 1.4:** Extended the existing `CrateQueryCompiler` switch for new operators instead of creating a separate `CrateDbFieldFilterMapper` class. Reason: SQL emission was already centralized there.
3. **Task 1.5:** Made `SortOrderItem` constructor public (was internal). Reason: cross-assembly use by asset-repo mapper.
4. **Task 1.5:** Expanded `FieldFilterOperatorDto` with Between/IsNull/IsNotNull + `FieldFilterDto` with `SecondaryValue`. Reason: required for end-to-end Between support.
5. **Task 3 (hydrator):** Added `SetAttributeRawValue` helper to `RtTypeWithAttributes`. Reason: hydrator needs to write to Attributes bag without going through typed setters.
6. **Task 4.4:** `MapAggregationRow` in `CrateDbStreamDataRepository` now also keys output by SQL alias (`{Function}_{path}`) so multiple stats on the same column don't clobber. Preserves path-keyed entries for the `.Rows` consumer.
7. **Task 5 deferred:** Per-type connection still returns cells-based `StreamDataEntityDto` rather than typed `Sd{CkType}`. Wiring compiled `Sd{CkType}DtoType` into `GraphTypesCache.GetStreamTypes()` requires nontrivial cache rewiring. Marked with `TODO(Phase 5.x)` comment near the per-type resolver. **Backlog — don't tackle unless explicitly asked.**

## Current test baseline (all green as of handoff)

- `octo-construction-kit-engine-mongodb/tests/StreamData.UnitTests` — **61/61**
- `octo-asset-repo-services/tests/AssetRepositoryServices.UnitTests` — **44/44**
- `octo-asset-repo-services/tests/AssetRepositoryServices.IntegrationTests` (StreamData filter) — **15/15**
- `octo-mesh-adapter/tests/MeshAdapter.Sdk.Tests` — **251/251**

User has manually verified: RT queries still work end-to-end against a locally running stack; stream queries on the frontend currently appear broken because the frontend hasn't been migrated yet. This is expected (backend GraphQL surface changed in Phase 4, frontend still targets old shape).

## GraphQL surface change (backend is ahead, frontend needs to catch up)

| Before | After |
|---|---|
| `{ streamData { streamDataQuery(rtId) { edges { node { cells { ... } } } } } }` | `{ streamData { streamDataQuery(rtId) { edges { node { rows { edges { node { cells { ... } } } } aggregations(aggregations: ...) { ... } } } } } } }` |
| `streamDataAggregationQuery(rtId)`, `streamDataGroupingAggregationQuery(rtId)`, `streamDataDownsamplingQuery(rtId)` (4 flat roots) | same single `streamDataQuery(rtId)` root, dispatches on loaded entity subtype |
| `transientStreamDataQuery(...)`, `transientStreamDataAggregationQuery(...)`, `transientStreamDataGroupedAggregationQuery(...)`, `transientStreamDataDownsamplingQuery(...)` (4 flat roots) | `transientStreamDataQuery { simple(...), aggregation(...), groupingAggregation(...), downsampling(...) }` (namespaced) |
| no generic | new `streamDataEntities(ckId, columnPaths, ...)` cells-based |
| per-type `streamDataMeteringPoint` etc. | unchanged (still cells-based — see deviation #7) |

New backend GraphQL types: `StreamDataQueryDescriptor`, `StreamDataTransient`, `StreamDataTransientQueryDescriptor`, `StreamDataEntityGeneric`, plus existing `StreamDataQueryRow`, `RtQueryCell`.

## Your job — Phase 7

Read the plan's Phase 7 section in full before starting (lines 2495+ in the plan file).

Phase 7 covers:
- **Task 7.1:** Update persistent query `.graphql` ops — collapse 4 → 1 op targeting the new descriptor shape. **First codegen is user-triggered.**
- **Task 7.2:** Update transient query `.graphql` ops — collapse 4 → 1 namespaced op. Agent runs codegen directly (Task 7.1 user-confirmed the backend).
- **Task 7.3:** Refactor `query-results-data-source.directive.ts` — collapse 4 `fetchStreamData*` methods → 1 variant-parameterized method; 7-way `queryType` switch → 3-way; delete `mapStreamDataAggregationType` adapter (~35 LoC).
- **Task 7.4:** Refactor `query-editor.component.ts` — collapse 7-case save switch → 3-case; introduce `isSimpleLike` / `isAggregationLike` helper predicates; flatten scattered `queryType !== 'simple' && queryType !== 'stream-data-simple'` sites.

**Key frontend paths:**
- `octo-frontend-refinery-studio/src/octo-mesh-refinery-studio/src/app/tenants/repository/query-builder/` — the query builder module
- `data-sources/query-results-data-source.directive.ts` (~896 lines, target heavy deletions)
- `query-editor/query-editor.component.ts` (~1,260 lines, target disambiguator flattening)
- `*.graphql` files for stream queries — find via `Grep` for `streamDataQuery` / `transientStreamDataQuery`

**Expected payoff:** ~585 LoC deleted across data-source + editor; 4 transient `.graphql` files collapse to 1.

**Verification after Phase 7:**
- Karma tests green: `cd octo-frontend-refinery-studio/src/octo-mesh-refinery-studio && npm test -- --watch=false`
- Manual smoke in dev: ASK the user via `AskUserQuestion` to build a persistent stream query, a transient aggregation, a downsampling, a per-type drilldown in the running UI.
- After smoke passes, use `superpowers:finishing-a-development-branch` skill for cleanup/PR.

## Recommended first moves as the new agent

1. Load `superpowers:using-superpowers` and `superpowers:subagent-driven-development` skills via the `Skill` tool.
2. Read the plan's Phase 7 in full.
3. Check task status: `TaskList`. Phase 7 should be the only remaining pending phase task.
4. Verify current state:
   - `git -C /Users/reimar/dev/meshmakers/branches/main/octo-frontend-refinery-studio status --short` (should be clean)
   - `git -C /Users/reimar/dev/meshmakers/branches/main/octo-frontend-refinery-studio branch --show-current` (should print `feature/reimar/stream-rt-query-symmetry`)
5. Explore the frontend query-builder structure with `Grep` before touching it.
6. Execute Task 7.1 first and stop at the codegen step to ASK THE USER to run it via `AskUserQuestion`.
7. After user confirms, proceed autonomously through Tasks 7.2–7.4, running codegen yourself between `.graphql` edits.
8. Final step: Karma + ask user for manual smoke via `AskUserQuestion`, then `superpowers:finishing-a-development-branch`.
