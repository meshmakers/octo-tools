---
description: The -Json envelope and the -EventsFile build event file that octo-tools commands share
applies_to: modules/OctoJsonOutput.psm1, tests/BuildEvents.Tests.ps1
---

### Machine-readable output (`-Json`)
Most query/status/compare commands (and many action commands) accept a `-Json` switch that suppresses
the colored human output and instead writes a single JSON document to the success stream, so the result
can be parsed by scripts, CI, or agents (`... -Json | ConvertFrom-Json`, or `... -Json > out.json`).

Every `-Json` document shares the same envelope:
```json
{ "schemaVersion": 1, "command": "Get-AllGitRepStatus", "timestamp": "<ISO-8601 UTC>", "data": <command-specific> }
```
- Query/compare commands put their results in `data` (e.g. an array of repo statuses, build results, version-diff rows).
- Pure action commands put a `{ "success": <bool>, "exitCode": <int>, ... }` summary in `data`.
- Interactive/blocking commands (the `Invoke-OctoCliLogin*` logins, `Invoke-MongoPortForward`, `Start-Octo`)
  do **not** support `-Json` — a single-emit JSON contract is meaningless while they block on input.
- Secret-bearing commands (`Get-RancherKubeConfig`, `Request-BreakGlassKubeConfig`) emit only safe metadata
  (cluster/context/expiry) under `-Json`; they never include the kubeconfig or any token.

**Build event file (`-EventsFile <path>`, Invoke-Build / Invoke-BuildRange / Invoke-BuildAll)** - live progress for a caller (octo-devstack): one compact JSON object per line (UTF-8, no BOM, flushed per line; `Write-OctoBuildEvent` in `OctoJsonOutput.psm1`, never throws), `{"schemaVersion":1,"ts":"<ISO-8601 UTC>","command":"<cmdlet>","event":"<event>",...}`. Events: `plan` {repos:[{repo,mode,action,reason,dependsOn}],count,parallel,maxParallel} (mode as in the plan: dotnet/script/frontend/zenon/none) · `repoStart` {repo,index (1-based),count} · `phase` {repo,phase: restore|build|tests|packages|purge} · `repoSkipped` {repo,index,count,reason,detail} (a repository that is not built: unchanged, not selected, excluded) · `repoDone` {repo,index,count,success,status,reason,seconds,buildSeconds,testSeconds,packageSeconds,copied,purged,logFile} (copied/purged = counts; BuildAll: null) · `done` {success,failedRepo,failedStep,elapsedSeconds}. Rules: a run that stops before its first `repoStart` (refusal, invalid arguments, missing folder, running services) writes only `done` (`failedStep: preflight`, `failedRepo: null`); once a repository started it always gets its `repoDone` before `done` - after a throw a `repoDone` with `success: false` and null durations/counts, and `done` names that repository and the running phase. Invoke-BuildAll stops before building when the lane cleanup (`failedStep: cleanup`) or the DebugL package purge (`purge`) fails, and stops after a repository whose package copy failed (`packages`). `done` is best-effort on Ctrl+C (the finally block may not run to the end). A relative `-EventsFile` resolves against `$PWD`. Nothing under `-WhatIf` / `-DryRun`; the `-Json` document is unchanged. Phases: Invoke-Build restore/build; Invoke-BuildRange build/tests/packages/purge; Invoke-BuildAll build (restore included)/packages.

**Test events (`Invoke-OctoTestRun -EventsFile <path>`)** - same file format, `command` = `Invoke-OctoTestRun`: `plan` {repo,environment,projects:[{project,runner: vstest|mtp|ng,docker,noBuild,buildReason,skip,noMatch}],count} · `lockWait` {path,timeoutSeconds,owner{pid,since,heldSeconds,command,lane,environment,repo,projects,..}} (once, when another run holds the machine-wide test lock) · `lockAcquired` {path,waitedSeconds} · `testProjectStart` {repo,project,index (1-based),count,runner,docker,noBuild,buildReason,calls} · `testProjectDone` {repo,project,index,count,success,state: passed|failed|error|noTests|noMatch,total,passed,failed,skipped,seconds,trx[],logFile} · `lockReleased` {path} · `done` {success,failedRepo,failedProject,failedStep: preflight|lock|docker|build|tests|canceled,elapsedSeconds,total,passed,failed,skipped}. A run that stops in the preflight writes only `done`; skipped projects (`-rerunFailed` without failed tests) get no start/done pair; nothing under `-WhatIf`.

The shared helpers live in `modules/OctoJsonOutput.psm1` (`Write-OctoJson`, `New-OctoActionResult`), loaded
first by `profile.ps1`. New cmdlets should reuse them rather than calling `ConvertTo-Json` directly (the
helper sets a safe `-Depth` so nested data isn't silently truncated).
