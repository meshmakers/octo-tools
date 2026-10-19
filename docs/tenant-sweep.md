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
| `-Json` | JSON envelope instead of row objects. |

Outcomes: `Ok` (exit 0), `Denied` (exit -4 or a denial/provisioning message), `Failed` (anything else, e.g. an
unknown context). The sweep runs the tenants one after the other and never stops at a failing tenant.

## GraphQL and files routes

* A GraphQL command for octo-cli is delivered by AB#7027. Until it is released the GraphQL sweeps have no
  supported path; as soon as it exists it is used like any other command here.
* The files-migration status routes (`system/v1/files/migration-status/{tenant}`, `files/capabilities`) have no
  CLI command and get none: the files migration is finished (AB#6183, decision 2026-10-19), the scripts that
  call them are retired, not ported.
* The Python helpers in `octo-claude-skills/skills/octo/scripts` use the active context's token for the
  context's **own** tenant and are not affected by the gate.
