# CI waste report (`Get-CiWasteReport`)

Answers one question every day: **how much of our CI work is duplicate?** (AB#6369, Feature AB#6333,
Epic AB#5711). It is read-only: HTTP GET against `dev.azure.com`, no build is queued or canceled,
nothing is written, the access token is never printed.

## Usage

```powershell
. ./modules/profile.ps1          # once per session
az login                         # once; the token is taken from `az account get-access-token`

Get-CiWasteReport                # last 24 h, human table
Get-CiWasteReport -Hours 168     # last 7 days
Get-CiWasteReport -Json          # standard octo-tools envelope for scripts / agents
Get-CiWasteReport -Json | ConvertFrom-Json | ForEach-Object { $_.data.totals.chain }
Get-CiWasteReport -AsOf '2026-10-10T10:25:00Z'   # window ending at a fixed instant (in-progress runs measured up to it)
```

Parameters: `-Hours` (1..720, default 24), `-AsOf` (default now), `-Organization` (`meshmakers`),
`-Project` (`OctoMesh`), `-CiPoolId` (45), `-CdPoolId` (46), `-JobRequestCount` (3000; a warning is
written if that does not reach back to the start of the window), `-ChainMap` (see below), `-Json`.

Endpoints (GET only): `_apis/build/builds?minTime&maxTime&queryOrder=queueTimeDescending` (paged by
continuation token), `_apis/distributedtask/pools/{id}/jobrequests`, `_apis/distributedtask/pools/{id}/agents`
(capacity = enabled agents).

## What it reports

Per CI definition (`name` ends with `-CI`):

| Field | Meaning |
|---|---|
| `runs`, `resourceTriggerRuns`, `resourceTriggerShare` | runs queued in the window, and how many by a pipeline-resource trigger |
| `duplicateRuns`, `duplicateShare`, `wastedMinutes` | strict same-commit duplicates and their agent-minutes (ceiling of the saving) |
| `mainRuns`, `redundantRuns`, `redundantMinutes` | chain definitions only: estimated provably redundant repeats on `main` (realistic saving) |
| `queueWaitP50/P90/MaxMinutes` | `startTime - queueTime` of the builds of that definition |
| `totalMinutes` | `startTime` to `finishTime`; in-progress runs until `-AsOf` |

Totals: `totals.ci` (all CI definitions) and `totals.chain` (the resource-trigger chain, with the redundant estimate).
Per pool (`pools[]`): job requests, queue wait p50/p90/max, `maxConcurrency` (instantaneous),
`sustainedPeak` (highest concurrency held at least 5 minutes), `avgConcurrency`, `percentTimeAtCapacity`.

JSON shape: `{ schemaVersion: 1, command: "Get-CiWasteReport", timestamp, data: { window, totals: { ci, chain }, definitions[], pools[], method } }`.

## Method

* **Strict duplicate**: same definition + `sourceVersion` + branch as another run in the window; per group the
  last succeeded run (else the last) is kept, the rest are duplicates. A rerun on the same commit is legitimate
  when an upstream package changed in between, so this is the **ceiling**.
* **Redundant (estimated)**: a non-canceled run of a chain definition on `refs/heads/main` whose inputs equal the
  inputs of an earlier non-canceled run. Inputs = own commit + `main` HEAD of every upstream definition at run
  start, reconstructed from the observed main runs (not from git; external NuGet changes are ignored; an upstream
  that was not seen yet in the window counts as "unknown" and compares equal to itself). This is the **realistic
  saving**.
* **Chain**: the pipeline-resource-trigger tree from `azure-pipelines.yml` on `main` (mm-common, distributedEventHub,
  construction-kit-engine, sdk, ck-engine-mongodb, common-services and its nine children, bot-services,
  communication-controller, ai-services, communication-sdk, mesh-adapter, frontend-libraries, refinery-studio). It is a
  constant in `modules/Get-CiWasteReport.psm1` (`$script:DefaultCiChainMap`); override with `-ChainMap` and update the
  constant when a trigger is added or removed.
* The calculation is a pure function, `Measure-CiWaste`, which the Pester tests drive with recorded data.

## Baseline 2026-10-10 (24 h, 2026-10-09 10:25Z to 2026-10-10 10:25Z, heavy release day)

Reproduced by `tests/CiWasteReport.Tests.ps1` from the scrubbed recording `tests/fixtures/ci-waste-baseline-20261010.json`
(analysis: `.po/ci-parallel-runs-analysis-20261010.md`):

| Metric | Analysis | Report |
|---|---|---|
| CI runs / resource-triggered | 328 / 168 | 328 / 168 |
| CI agent-minutes / of them resource-triggered | 4,920 / 2,766 | 4,915 / 2,764 |
| Chain runs | 284 | 284 |
| Same-commit duplicates in the chain | 170 (60 %) | 170 (59.9 %) |
| Wasted agent-minutes (ceiling) | about 2,580 of 4,277 | 2,579 of 4,271 |
| ai-services: runs / via trigger / duplicates / wasted min | 16 / 13 / 11 / 551 | 16 / 13 / 11 / 549 |
| Redundant repeats on main (realistic saving) | 103 of 219 runs (47 %), about 1,400 of 3,400 min (40 %) | 100 of 215 runs (46.5 %), 1,345 of 3,418 min (39 %) |
| CI pool (8 agents) wait p50 / p90 / max | 0 / 4 / 24 min | 0 / 4.1 / 24.0 min |
| CI pool concurrency: peak / average | 6 / 2.9 | sustained peak 6 (instantaneous 8 for about 1 min) / 2.86 |
| CD pool (6 agents) wait p90 / max, time at capacity | 2 / 28 min, 3 % | 1.8 / 27.8 min, 3.8 % |

The redundant estimate differs slightly (about 3 % in count, 4 % in minutes) because the analysis selected the runs
slightly differently; the shares agree within 1 point. The "peak 6" of the analysis is the sustained peak.

Targets of Feature AB#6333: strict duplicate share below 15 % (baseline 60 %), wasted minutes -80 %, queue wait p90 below 5 minutes.

## Running it daily

The report needs only `az login` and the profile. For a daily record:
`Get-CiWasteReport -Json > ci-waste-$(Get-Date -Format yyyyMMdd).json` and compare `data.totals.chain.duplicateShare` and
`wastedMinutes` with the baseline above. The Release-Trains wiki page links here; publish the note below with the merge.

### Note for the Release-Trains wiki / Feature AB#6333 (prepare, publish with the merge)

> **CI waste report.** `Get-CiWasteReport` (octo-tools, `docs/ci-waste-report.md`) shows per CI definition how many runs
> repeat an already built commit and how many agent-minutes that costs; `-Json` for scripts. Baseline 2026-10-10 (heavy release
> day, 24 h): 170 of 284 chain runs (60 %) were same-commit duplicates, about 2,579 of 4,271 chain minutes; about 1,345
> minutes (39 %) were provably redundant repeats on main. Target of AB#6333: below 15 % duplicates.

## Tests

`Invoke-Pester ./tests/CiWasteReport.Tests.ps1` (Pester 5 and 6). No network and no `az login`: the REST layer is mocked and the
baseline test replays the fixture. The fixture keeps only the fields the report reads; commit ids are pseudonymised, build ids
renumbered, and there are no URLs, people, agent names or tokens (a test enforces this).
