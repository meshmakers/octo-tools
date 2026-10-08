OctoMesh is a powerful tool designed to seamlessly transform raw data into meaningful information, all while ensuring that the data is imbued with the context it needs to be truly insightful. Whether you're working with structured data, unstructured data, or anything in between, OctoMesh empowers you to harness the full potential of your data.

This repository contains tools to simplify the development and deployment of OctoMesh. It includes a PowerShell profile to simplify the development process and a set of scripts to manage the infrastructure with docker-compose.

# Getting started

The complete documentation of OctoMesh is available at https://docs.meshmakers.cloud.

# Configuration

Some of the tooling needs values that are environment-specific (the OctoMesh
installations you want to talk to, your container registry, your Rancher /
Vault / Semaphore endpoints, your Telerik Kendo UI license). Those don't live
in this repo — they live in a per-developer config file outside of git.

1. **Create the config directory** and copy the example file there:

   ```bash
   mkdir -p ~/.config/octo-tools
   cp installations.example.json ~/.config/octo-tools/installations.json
   ```

   You can put the file somewhere else and point `OCTO_TOOLS_CONFIG` at it.

2. **Edit it** for your environment. See
   [`docs/installations-config.md`](docs/installations-config.md) for the
   schema reference. The minimum useful content is one `installations[]`
   entry — `local` (which the example provides) is enough for an
   all-on-localhost dev loop.

3. **Add a private profile** for anything that doesn't belong in a checked-in
   config (in particular: your Telerik Kendo UI license, your Rancher API
   token):

   * macOS / Linux: `~/.config/powershell/Microsoft.PowerShell_profile_private.ps1`
   * Windows: `~/.pwsh/profile.ps1`

   Typical content:

   ```powershell
   $env:TELERIK_LICENSE   = "<your Kendo UI license JWT — see https://www.telerik.com/account/your-licenses>"
   $env:RANCHER_API_TOKEN = "token-xxxxx:secret"
   ```

   `modules/profile.ps1` sources this file at the end of its bootstrap, so
   anything set here wins over the config-file defaults.

# Fast local loop (partial DebugL rebuilds)

`Invoke-BuildAll -configuration DebugL` is the full reset: it wipes `<checkout>/nuget`, deletes every
`~/.nuget/packages/meshmakers.*/999.0.0` folder, forces a restore and builds every solution including
its tests. For day-to-day work on a library in the chain (e.g. the construction-kit engine) use
`Invoke-BuildRange`, which rebuilds only a slice of the same build order:

```powershell
# 1. See what would happen (repositories, src/ projects, global-cache folders to purge, running services)
Invoke-BuildRange -branch main -from octo-construction-kit-engine -to octo-common-services `
    -include octo-asset-repo-services,octo-identity-services -WhatIf

# 2. Stop the local services (their bin/DebugL output is overwritten), build, start again
Stop-Octo -branch main
Invoke-BuildRange -branch main -from octo-construction-kit-engine -to octo-common-services `
    -include octo-asset-repo-services,octo-identity-services
Start-Octo -branch main -configuration DebugL -nonInteractive $true
```

Per repository, in build order:

1. `dotnet build -c DebugL -nodeReuse:false` of the solution's `src/` projects only (a temporary
   `.slnf` in the temp folder; `-includeTests` builds the whole solution). There is no forced
   restore: the implicit restore only re-extracts the packages that were purged.
2. `Copy-NuGetPackages -modifiedSince <build start>` copies the packages this build (re)wrote into
   `<checkout>/nuget`. Stale nupkgs of removed projects (e.g. `Sdk.Common.Web` in `octo-sdk/bin`
   after it moved to `octo-communication-sdk`) are neither copied nor purged.
3. Exactly those packages are purged from `~/.nuget/packages/<id>/999.0.0`, so the next repository
   restores them fresh from `<checkout>/nuget`. Nothing else in the cache and nothing else in
   `<checkout>/nuget` is touched.

It stops at the first failing repository (fail fast, prints the repository name and the error lines
of its `Invoke-Build.log`) and prints per-repository timings at the end (`-Json` for a
machine-readable result). It refuses to start while processes run out of a repository in the range
(`Start-Octo` services); pass `-stopServices` to send `Stop-Octo` and wait, or
`-ignoreRunningServices` to build anyway. It never kills dotnet processes.

| Parameter | Meaning |
|-----------|---------|
| `-from` / `-to` | First / last repository of the range (inclusive; `-to` defaults to `-from`). Exact name, name without `octo-`, or a unique substring. |
| `-include` / `-exclude` | Add repositories outside the range (kept at their build-order position) / skip repositories inside it. |
| `-includeTests` | Build the whole solution instead of `src/` only. |
| `-excludeFrontend` | Default `$true`; frontends produce no NuGet packages. |
| `-configuration` | Default `DebugL`. Copy and purge only run for DebugL. |
| `-msbuildProperties` | Extra MSBuild global properties (`-p:Name=Value`) for the `dotnet build` of **every** repository in the run. Global properties override values set in project files. `Invoke-BuildAll` and `Invoke-Build` accept the same parameter. Not applied to `build.ps1` / frontend / zenon builds (warning). Do **not** use it for `OctoPublishCkModel`: that stops every CK model of the run from being published into the local catalog, so downstream CK compiles see stale models (a warning is printed when `OctoPublishCkModel=false` applies to more than one repository). |
| `-msbuildPropertiesPerRepo` | Properties for single repositories (overriding `-msbuildProperties`), e.g. `@{ 'octo-identity-services' = @{ OctoPublishCkModel = 'false' } }` to keep only identity's CK model out of the shared local catalog. Also on `Invoke-BuildAll`. |
| `-purgeStaleCache` | Purge global-cache `999.0.0` folders whose recorded SHA-512 differs from `<checkout>/nuget` before the first build (see below). Without it they are only reported. |
| `-WhatIf` / `-Json` | Print the plan only / emit one JSON document (early exits emit `success: false` and set `$LASTEXITCODE` to 1). |

The build order (`mm-*` -> pinned `octo-*` -> remaining `octo-*` alphabetically) lives in
`modules/OctoBuildOrder.psm1` (`Get-OctoBuildOrder`) and is shared with `Invoke-BuildAll`.
`Get-OctoBuildOrder -branchRootPath <checkout> | Format-Table Name, Group` shows it.

`Copy-AllNuGetPackages -branch main` (also used by `Sync-NuGetPackages`) copies the newest file per
package when several repositories contain the same `Meshmakers.*.999.0.0.nupkg` (e.g. a stale
`Sdk.Common.Web` in `octo-sdk/bin` after the project moved to `octo-communication-sdk`), warns about
such duplicates and never replaces a newer package already in `<checkout>/nuget`.

**Stale global-cache packages.** `~/.nuget/packages` is shared by all checkouts (e.g. `main` and `dev`).
Before building, `Invoke-BuildRange` compares every `<checkout>/nuget/<id>.999.0.0.nupkg` with the
SHA-512 NuGet recorded for `~/.nuget/packages/<id>/999.0.0` (`<id>.999.0.0.nupkg.sha512`). A mismatch
(e.g. the folder was extracted from the dev checkout's build) or a missing hash file is reported in
`-WhatIf`, as a warning and in `-Json` (`staleGlobalCache`); `-purgeStaleCache` deletes those folders
so the restores in this checkout use its own packages.

Notes for the loop:

* Run a full `Invoke-BuildAll -branch main -configuration DebugL -excludeFrontend $true` once after a
  fresh clone, a pull or a branch switch. Use `Invoke-BuildRange` afterwards. When restores fail with
  NU1101/NU1102 for a `999.0.0` package, the chain is out of sync: run `Invoke-BuildAll` again.
* Repositories outside the range are not rebuilt. If they consume a rebuilt package they pick it up
  on their next build (its global-cache copy was purged).
* `octo-construction-kit` packages are not consumed by the service chain - skip them for engine changes.
* The `System*` CK models are embedded in the service DLLs and are imported automatically when a
  tenant is resolved (with a downgrade guard), so a rebuilt and restarted service brings its newer
  System model along. The local CK catalog is `<checkout>/.octo/local-catalog` (Start-Octo points
  `OCTO_LocalFileSystemCatalog__RootPath` at it).

# Tests

Pester tests for the build tooling live in `tests/` (they run against a fake checkout in `TestDrive`
and never build or touch the real NuGet folders):

```powershell
Install-Module Pester -MinimumVersion 5.5 -Scope CurrentUser   # once
Invoke-Pester ./tests
```

# Customizing Windows Terminal Profile

1. Create Environment Variable MESHMAKERS with path to the OctoMesh repository.
2. In Windows add a new Profile and set the following settings in json:

**Terminal Profile:**

```json
{
  "altGrAliasing": true,
  "antialiasingMode": "grayscale",
  "backgroundImage": "%MESHMAKERS%\\octo-tools\\assets\\Logo_schwarz.png",
  "backgroundImageAlignment": "center",
  "backgroundImageOpacity": 0.3,
  "backgroundImageStretchMode": "fill",
  "closeOnExit": "automatic",
  "colorScheme": "Meshmakers",
  "commandline": "pwsh.exe -NoExit -ExecutionPolicy Bypass -Command . '%MESHMAKERS%\\octo-tools\\modules\\profile.ps1'",
  "cursorShape": "bar",
  "guid": "{df3c5fa9-c722-465c-b399-0ffc8bd1ba96}",
  "hidden": false,
  "historySize": 90001,
  "icon": "%MESHMAKERS%\\octo-tools\\assets\\meshmakers64.png",
  "name": "MeshConsole",
  "padding": "8, 8, 8, 8",
  "snapOnInput": true,
  "startingDirectory": "%MESHMAKERS%",
  "useAcrylic": true
}
```

**Color Scheme:**

```json
{
  "background": "#3A695C",
  "black": "#0C0C0C",
  "blue": "#0037DA",
  "brightBlack": "#767676",
  "brightBlue": "#3B78FF",
  "brightCyan": "#61D6D6",
  "brightGreen": "#16C60C",
  "brightPurple": "#B4009E",
  "brightRed": "#E74856",
  "brightWhite": "#F2F2F2",
  "brightYellow": "#F9F1A5",
  "cursorColor": "#FFFFFF",
  "cyan": "#3A96DD",
  "foreground": "#FFFFFF",
  "green": "#13A10E",
  "name": "Meshmakers",
  "purple": "#881798",
  "red": "#C50F1F",
  "selectionBackground": "#FFFFFF",
  "white": "#CCCCCC",
  "yellow": "#C19C00"
}
```

3. Further customization:

create a folder in the users directory: `.pwsh` and add a `profile.ps1`
This gets loaded when the terminal starts. You can for example disable the octo promt (`OCTO >`) by disabling `$Global:WantPromt = $true` in your custom `profile.ps1`.

# AI Bastion

The `Invoke-AiBastion` module drives the operator-side flow that registers an
Anthropic subscription token on an OctoMesh tenant — the bastion CLI from
ADR-15 / ADR-18 / #4123. Two cmdlets are exported once `profile.ps1` is sourced:

```powershell
Register-AiBastion -Tenant acme -AdapterUrl https://ai.example.com
Get-AiBastionStatus -Tenant acme -AdapterUrl https://ai.example.com
```

Authentication uses the operator's own OctoMesh OAuth token (the same one
`octo-cli login` deposits) — either passed via `-BearerToken` or read from
the `OCTO_BASTION_TOKEN` environment variable. The Anthropic device-code
flow runs on the operator's terminal; the resulting access + refresh token
pair is POSTed to the adapter's
`POST /{tenantId}/v1/credentials/register` endpoint, which encrypts both
tokens at rest before persistence.

Plaintext token material is held in process memory for the minimum time
needed and explicitly overwritten + GC-collected in a `finally` block, so
that Ctrl-C while waiting for the user to approve the device code still
wipes the credentials.

## Bastion host setup

The intended deployment runs this module on a dedicated bastion host.
Allowed SSH users are managed in the OctoMesh identity service; the host's
`/etc/ssh/sshd_config` restricts inbound shells to a dedicated operator
group. Each operator's session exports `OCTO_BASTION_TOKEN` from their
`octo-cli` login and runs `Register-AiBastion` with the tenant slug they're
onboarding.

The cmdlet doesn't persist anything to disk; the only artefact of a
successful run is the lease the adapter records server-side and a one-line
status echo on stdout.

# Support and Feedback

If you encounter any issues or have questions while using OctoMesh, please don't hesitate to reach out to our support team at support@meshmakers.io. We value your feedback and are committed to helping you make the most of OctoMesh.

# License

OctoMesh is released under the MIT License. Feel free to use and modify it according to your needs, and we encourage contributions from the community to enhance the system further.

Thank you for choosing DTS as your data transformation solution. We look forward to seeing how it empowers you to turn data into valuable insights.

Happy transforming! 🚀
