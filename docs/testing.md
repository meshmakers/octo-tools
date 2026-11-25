---
description: How the Pester tests are installed, written and run - fake checkout, no real builds, parallel runner, keeping the suite fast
applies_to: tests/**
---
# Tests (Pester 5)

The tests in `tests/` are Pester 5 tests (`Invoke-Pester ./tests`). They use a fake checkout in `TestDrive` and mock the
build step - never run real builds or touch the real NuGet folders from tests.

## Installing Pester 5

`Install-Module Pester -MinimumVersion 5.5 -MaximumVersion 5.99 -Scope CurrentUser`. Without `-MaximumVersion` you get
Pester 6. On Windows with Controlled Folder Access, which blocks `Documents\PowerShell\Modules`, run
`New-Item -ItemType Directory -Force ~/.local/share/powershell/Modules`, then
`Save-Module ... -Path ~/.local/share/powershell/Modules`, which `profile.ps1` adds to `PSModulePath` on Windows - load
the profile or add the folder to `$env:PSModulePath` yourself; also for `powershell-yaml`.

## Running them

- `./tests/Invoke-ParallelPester.ps1 [-Path <folder|files>] [-ThrottleLimit <n>] [-PassThru]` runs every `*.Tests.ps1`
  in its own pwsh process (default: up to 8 at a time, biggest files first) and merges the results; exit code 1 when any
  file has a failed test, a failed block or container, no result or no test at all (`tests/ParallelPester.Tests.ps1`).
  The workflow `.github/workflows/pester.yml` runs it on every pull request and every push to `main`, after loading
  Pester 5.5-5.99.
- `Invoke-Pester ./tests` stays the reference run.

## Keeping the suite fast

- Fixtures go into `$TestDrive`, never `[IO.Path]::GetTempPath()` (PowerShell's file cmdlets cost 30-150 ms per call
  below a temp folder with tens of thousands of entries).
- A fixture that needs many `git` calls is built once per file and copied per test (`New-FakeWorkspace` /
  `Initialize-FakeWorkspaceTemplate` in `tests/OctoEnvironment.TestHelpers.ps1`: a native process started from pwsh
  costs 15-30 ms).
- A test file that grows past about a minute is split (the `OctoEnvironment*.Tests.ps1` files share that helper),
  because the parallel run is as slow as its slowest file.

## Shared machine state

The test lock is a machine-wide file: the lock tests in `tests/OctoTests.Tests.ps1` pass a `-LockPath` below `TestDrive`
(lines 39 and 140), and the Docker engine is mocked through `Invoke-OctoDocker` (line 303). Follow the same seams in new
tests (details: `docs/running-tests.md`).
