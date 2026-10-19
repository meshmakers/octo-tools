# Working on many tenants: `Invoke-OctoTenantSweep` (AB#6840)

Since the tenant gate (AB#5054 / AB#6728) a call that addresses tenant X must carry a token for tenant X.
Scripts that copied the token out of the octo-cli context file and sent it to a child tenant stop working by
design. `Invoke-OctoTenantSweep` is the supported replacement: a thin loop around
`octo-cli --context <name> -c <command>`. octo-cli does the authentication (AB#6836); the helper

* never reads, prints, logs or writes a token and never opens the octo-cli context file,
* never changes the active context (it always passes `--context`),
* needs octo-cli **3.5.27 or newer** and stops with a clear message otherwise,
* scrubs token-shaped text (JWTs, `bearer ...`, `access_token=...`) from everything it shows or returns.

## Prerequisites per tenant

1. **A context for the tenant** (commands that act on "the context's tenant", e.g. `LibraryStatus`,
   blueprint commands):
   `Register-OctoCliContext -Installation <inst> -TenantId a,b,c -NoSwitch` (add `-NoLogin` when the contexts
   are signed in some other way). Contexts are named `<inst>[_<UriSuffix>]_<tenant>`.
2. **Authority in the tenant.** A root-tenant operator has no implicit rights in a child tenant. Provision the
   operator once per child tenant, also for new tenants:
   `octo-cli -c ProvisionCurrentUser -ttid <child>` (or sweep it: see the second example below).
3. **Sign-in.** A context whose token belongs to another tenant is exchanged by octo-cli per tenant (cached,
   renewed silently). A context signed in for its own tenant (device flow, `LogInClientCredentials`, CI) needs
   no exchange.

A tenant where the operator is not provisioned fails with exit code -4 and a message naming the tenant and the
cause (`ProvisionCurrentUser -ttid <tenant>`). The sweep reports it as **Denied** and continues.

## Usage

```powershell
# What would run? (lists tenants and the exact octo-cli calls, runs nothing)
Invoke-OctoTenantSweep -Installation test2 -Tenant tecob,lkv,wwc26 -CliArguments '-c','LibraryStatus','-io' -WhatIf

# Run it; one row per tenant: Tenant, Context, Outcome (Ok|Denied|Failed), ExitCode, Cause
Invoke-OctoTenantSweep -Installation test2 -Tenant tecob,lkv,wwc26 -CliArguments '-c','LibraryStatus','-io'

# Commands with their own tenant argument: one context, {tenant} is substituted; tenants from GetTenants --all
Invoke-OctoTenantSweep -Context test2_octosystem -AllTenants -Exclude octosystem `
    -CliArguments '-c','ProvisionCurrentUser','-ttid','{tenant}'

# Machine-readable (standard octo-tools envelope: data.summary + data.results)
Invoke-OctoTenantSweep -Installation test2 -Tenant a,b -CliArguments '-c','ClearCache' -Json | ConvertFrom-Json
```

| Parameter | Meaning |
|---|---|
| `-CliArguments` | octo-cli arguments after the context; `{tenant}` is replaced. `--context` is rejected. |
| `-Installation` / `-UriSuffix` | Context name per tenant `<inst>[_<suffix>]_{tenant}` (what `Register-OctoCliContext` creates). |
| `-ContextTemplate` | Any other naming, must contain `{tenant}`. |
| `-Context` | One fixed context (tenant-argument commands; the context used for `-AllTenants`). |
| `-Tenant` / `-AllTenants` / `-Exclude` | The tenant list; `-AllTenants` runs `GetTenants --all` (needs a system tenant context). |
| `-WhatIf` | Dry run: rows with outcome `Planned`. |
| `-ShowOutput` | Also write the scrubbed octo-cli output per tenant to the information stream. |
| `-IncludeOutput` | Adds `Stdout` (scrubbed octo-cli standard output, e.g. the GraphQL response) to every row. |
| `-Json` | JSON envelope instead of row objects. |

Outcomes: `Ok` (exit 0), `Denied` (exit -4 or a denial/provisioning message), `Failed` (anything else, e.g. an
unknown context). The sweep runs the tenants one after the other and never stops at a failing tenant.

## GraphQL over many tenants

`octo-cli -c GraphQl -tid <tenant> (-q <text> | -f <file> | -si) [-vars <json|@file>] [-on <operation>]` (AB#7027,
octo-cli on `main`) sends one query or mutation to `tenants/<tenant>/GraphQL` with the token for that tenant (same rule
as every other command, AB#6836) and writes the response JSON unmodified to standard output (banner and log lines go to
standard error). That makes it a normal sweep command; `-IncludeOutput` adds the scrubbed standard output to every row:

```powershell
$q = '{ runtime { runtimeEntities(ckId:"System/Entity", first:1) { totalCount } } }'

# one system-tenant context, the tenant goes into -tid (read-only query here; a mutation works the same way)
Invoke-OctoTenantSweep -Context test2_octosystem -Tenant tecob,lkv,wwc26 -IncludeOutput `\
    -CliArguments '-c','GraphQl','-tid','{tenant}','-q',$q |
  ForEach-Object {
      [pscustomobject]@{
          Tenant = $_.Tenant; Outcome = $_.Outcome; Cause = $_.Cause
          Total  = if ($_.Outcome -eq 'Ok') { ($_.Stdout | ConvertFrom-Json).data.runtime.runtimeEntities.totalCount }
      }
  }

# long documents: -f query.graphql, variables: -vars '{"first":10}' or -vars @vars.json
```

A GraphQL error in the response (non-empty `errors`) makes octo-cli exit -5, so the row is `Failed` with the first message
as cause; a tenant without provisioning is `Denied`. Never copy a token into a `curl` or Python call instead.

## Files routes, pool deploy, Python helpers

* The files-migration status routes (`system/v1/files/migration-status/{tenant}`, `files/capabilities`) have no
  CLI command and get none: the files migration is finished (AB#6183, decision 2026-10-19), the scripts that
  call them are retired, not ported.
* Impersonation loops use the existing command `SwitchServiceAccountsToImpersonation` (sweep it with `-Context` and
  `-tid {tenant}`), not curl against `serviceAccount/switchToImpersonation`.
* Deploying a communication pool (`POST .../v1/Pool/deploy?poolRtId=`) has **no CLI command** (known gap, not part of
  AB#6840). The call needs a token issued for that tenant (a context of that tenant); do not take it from another context.
* The Python helpers in `octo-claude-skills/skills/octo/scripts` use the active context's token for the
  context's **own** tenant and are not affected by the gate.
