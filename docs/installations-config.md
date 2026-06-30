# octo-tools configuration

Environment-specific values for the octo-tools PowerShell modules live in a
per-developer JSON config file, **not** in this repo. This page describes the
file format.

## Location

Resolution order:

1. `$env:OCTO_TOOLS_CONFIG` if set — explicit override, useful for CI / tests.
2. `~/.config/octo-tools/installations.json` — POSIX convention, used on every OS.

There is no default; if the file does not exist, cmdlets that depend on it
throw a clear error pointing back to this page.

A starting template lives at the repo root as
[`installations.example.json`](../installations.example.json). Copy it to the
resolved path and edit it for your environment.

## Schema

```json
{
  "registry":  { "url": "..." },
  "rancher":   { "url": "..." },
  "vault":     { "addr": "..." },
  "semaphore": {
    "url": "...",
    "breakGlassProjectId":  1,
    "breakGlassTemplateId": 1
  },
  "aiBastion": { "url": "..." },

  "installations": [
    {
      "name": "local",
      "services": {
        "assets":        "https://localhost:5001/",
        "identity":      "https://localhost:5003/",
        "bots":          "https://localhost:5009/",
        "communication": "https://localhost:5015/",
        "reporting":     "https://localhost:5007/",
        "ai":            "https://localhost:5019/"
      }
    },
    {
      "name": "example-test",
      "services": {
        "assets":        "https://assets{0}.test.example.com/",
        "identity":      "https://connect{0}.test.example.com/",
        "bots":          "https://bots{0}.test.example.com/",
        "communication": "https://communication{0}.test.example.com/",
        "reporting":     "https://reporting{0}.test.example.com/",
        "ai":            "https://ai{0}.test.example.com/"
      }
    }
  ]
}
```

Every top-level block is optional. Cmdlets only fail if the specific block
they need is missing.

### `registry`

| Field | Description |
| --- | --- |
| `url` | Default dev container registry. Used by `Install-OctoKubernetes -DevRegistry` and the `image.privateRegistry` lookup in `Deploy-OctoOperator`. |

### `rancher`

| Field | Description |
| --- | --- |
| `url`  | Rancher base URL. Exported as `RANCHER_URL` by `profile.ps1` for `Get-RancherKubeConfig`. |

The corresponding `RANCHER_API_TOKEN` belongs in your **private profile**, not
in this config file (it's a personal credential, format `token-xxxxx:secret`).

### `vault`

| Field | Description |
| --- | --- |
| `addr` | Vault base URL. Exported as `VAULT_ADDR` by `profile.ps1`. |

### `semaphore`

| Field | Description |
| --- | --- |
| `url`                  | Semaphore base URL. Exported as `SEMAPHORE_URL`. |
| `breakGlassProjectId`  | Project id of the break-glass Ansible template. Exported as `SEMAPHORE_BREAKGLASS_PROJECT_ID`. |
| `breakGlassTemplateId` | Template id of the break-glass Ansible template. Exported as `SEMAPHORE_BREAKGLASS_TEMPLATE_ID`. |

`Request-BreakGlassKubeConfig` reads these via their env-var form, so values
in your private profile override the config-file ones.

### `aiBastion`

| Field | Description |
| --- | --- |
| `url`  | Default `-AdapterUrl` for `Register-AiBastion` / `Get-AiBastionStatus`. |

### `installations[]`

One entry per OctoMesh installation you want `Register-OctoCliContext` to know
about. The `name` is what you pass via the `-Installation` parameter.

| Field | Description |
| --- | --- |
| `name`     | Identifier used on the `-Installation` parameter and in the resulting `octo-cli` context name. |
| `services` | Map of service-key → URL template. Required keys: `assets`, `identity`, `bots`, `communication`. Optional: `reporting`, `ai`. |

#### Service-URL templates

Each service URL is treated as a **format string**. `{0}` is replaced with
`-$UriSuffix` if you pass `-UriSuffix`, or with the empty string otherwise.
That lets one entry cover both the base environment and its preview
sub-environments:

```
"assets": "https://assets{0}.test.example.com/"

  Register-OctoCliContext -Installation example-test -TenantId mytenant
  → https://assets.test.example.com/

  Register-OctoCliContext -Installation example-test -TenantId mytenant -UriSuffix pr123
  → https://assets-pr123.test.example.com/
```

For installations that don't have a suffix concept (e.g. `local`), simply omit
the `{0}` placeholder from the URL:

```
"assets": "https://localhost:5001/"
```

## Caching

`Get-OctoToolsConfig` caches the parsed config for the lifetime of the
PowerShell session. After editing the file, call `Get-OctoToolsConfig -Force`
to pick up the change without restarting your shell.

## Why JSON

PowerShell can parse JSON natively (`ConvertFrom-Json`) without any extra
modules — fewer moving parts than YAML.
