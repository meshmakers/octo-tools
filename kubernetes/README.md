# OctoMesh Local Kubernetes Dev Environment

A local [kind](https://kind.sigs.k8s.io/) cluster that runs the OctoMesh **infrastructure**
(MongoDB / RabbitMQ / CrateDB, single-node) plus the **CRDs** and the **Communication
Operator**, so you can exercise the Helm-/operator-driven per-tenant deployment of
mesh-adapters and arbitrary applications locally. The core .NET services stay host
processes (`Start-Octo`); only what's needed to deploy adapters/apps runs in the cluster.

Design spec: `../docs/superpowers/specs/2026-05-30-octomesh-local-k8s-infra-design.md`
Implementation plan: `../docs/superpowers/plans/2026-05-30-local-k8s-dev-env.md`

## Architecture

```
HOST (macOS / Windows)                       kind cluster "kind" (Docker)
─────────────────────────────────           ─────────────────────────────────────────────
Start-Octo host processes (HTTPS):           ns octo-infra:
  identity 5003 · asset-repo 5001              mongodb (1-member RS "rs", keyFile)
  communication-controller 5015 · bot 5009     rabbitmq · cratedb (single-node)
Refinery Studio (ng serve 4200)              ns octo-operator-system:
octo-cli                                       CRDs + communication-operator (central)
                                             ns octo:
  ── localhost:27017/5672/5432/4301 ─────▶     adapter / application pods
     (NodePort + kind extraPortMappings)       (helm-deployed per tenant by the operator)
  operator/adapters ── https://<host-LAN-IP>:5015 ──▶ host controller
```

- **Host → in-cluster infra:** NodePort Services + kind `extraPortMappings` pin the infra to
  the *same* localhost ports used today, so `Start-Octo` services connect with **no config
  change** (they already run with `OCTO_SYSTEM__USEDIRECTCONNECTION=true`).
- **Cluster → host controller:** the operator and adapter pods reach the host-process
  Communication Controller via the kind node's **Docker host-gateway** (`host.docker.internal`,
  e.g. `192.168.65.254`) — a stable address that does *not* change with your LAN/VPN/Tailscale IP —
  with TLS validation bypassed (`adapterIgnoreCertificateValidation: true`) because the host serves a `localhost`
  dev cert. **On Docker CE / Linux** the node has no `host.docker.internal` entry, so
  `Deploy-OctoOperator` falls back to the node's default-route gateway (the kind bridge gateway,
  e.g. `172.18.0.1`) — equally stable for the cluster's lifetime and routes to the host. For this
  to work the host services must listen on all interfaces (they bind `*:5015` etc., so they do).

### In-cluster DNS + host-port contract

| Component | In-cluster DNS | Host port |
|---|---|---|
| MongoDB | `mongodb-0.mongodb.octo-infra.svc.cluster.local:27017` (RS `rs`) | `localhost:27017` |
| RabbitMQ | `rabbitmq.octo-infra.svc.cluster.local:5672` | `localhost:5672` (AMQP) / `15672` (mgmt) |
| CrateDB | `cratedb.octo-infra.svc.cluster.local` (psql 5432 / http 4200) | `localhost:5432` (psql) / `4301` (http UI) |

## Prerequisites

On PATH: `kind` (v0.31+), `kubectl`, `helm` (v3), `docker` (daemon running), `openssl`,
and `mongosh` (optional, for host verification). Install kind on macOS with `brew install kind`;
on **Windows** (Docker Desktop) with `winget install Kubernetes.kind` — then **restart your shell**
so `kind` resolves on PATH (winget updates the persisted user PATH, not running processes).
On **Linux** (Docker CE/Engine) there is no bundled installer — drop the `kind`/`kubectl`/`helm`
binaries on PATH manually (see QUICKSTART → Prerequisites; use the `arm64` URLs on ARM hosts).
The cmdlets run under `pwsh` on Linux exactly as on macOS/Windows.
`octo-helm-core` must be checked out next to the other repos (it ships the CRDs + operator chart).

> **Port collision with docker-compose infra.** The kind infra binds the *same* host ports
> (27017/5672/15672/5432/4301) as the legacy `Start-OctoInfrastructure` docker-compose stack.
> They **cannot run at the same time.** `Install-OctoKubernetes` refuses to run while the
> docker-compose containers (`mongo-0.mongo`, `rabbitmq`, `cratedb01`) are up — stop them first
> with `Stop-OctoInfrastructure`.

Load the cmdlets:
```powershell
. ./octo-tools/modules/profile.ps1
```

## One-time / cluster bring-up

```powershell
# kind cluster + CRDs + namespaces + in-cluster infra (mongo/rabbit/crate) + Mongo RS init +
# ingress-nginx + cert-manager (mm-cloud-issuer, CA trusted) + the Communication Operator.
# Idempotent; refuses if the docker-compose infra is running.
Install-OctoKubernetes                          # operator: latest published image
Install-OctoKubernetes -Configuration DebugL    # operator: BUILT from octo-communication-operator source
```

The Communication Operator is now deployed by `Install-OctoKubernetes` itself: with
`-Configuration DebugL` it is built from the `octo-communication-operator` source and loaded into
kind (version-matched to your local DebugL services); any other value installs the latest
published operator image. `-SkipOperator` skips it. `Deploy-OctoOperator` is still available to
(re)deploy the operator standalone — for example after changing operator code — with these options:
- `-ImageTag <tag>` — operator image tag (default `3.3.108.0`, the newest published; there is no `latest`).
- `-ControllerHost <ip>` — override the host address the operator/adapters use to reach the
  controller. By default the cmdlet uses the kind node's Docker host-gateway
  (`host.docker.internal`, e.g. `192.168.65.254`) — a **stable** address that does not change with
  your LAN/VPN/Tailscale IP. On Docker CE / Linux (no `host.docker.internal`) it auto-falls back to
  the kind bridge gateway (e.g. `172.18.0.1`), which is equally stable — so you normally don't need
  to override there either. Only pass this if neither is reachable (e.g. an unusual network setup).
- `-BuildLocal` — build the operator image from `octo-communication-operator` source and load
  it into kind instead of pulling the published image. Use this when you've changed operator
  code and need it version-matched to your locally-built controller.

## Daily development

```powershell
# Build the backend (host processes), then start them. They connect to the kind infra
# on the same localhost ports as before — no config change needed.
Invoke-BuildAll -configuration DebugL -excludeFrontend $true
Start-Octo -configuration DebugL

# Authenticate the CLI
Invoke-OctoCliLoginLocal

# Frontends keep running as host dev servers (hot reload), pointed at the host backends:
#   cd octo-frontend-refinery-studio/src/octo-mesh-refinery-studio ; npm start   (https://localhost:4200)
```

Status at any time:
```powershell
Get-OctoKubernetesStatus
```

## Deploying adapters and applications

This is the capability the local cluster unlocks — the same operator/Helm path used in the cloud.

**Per-tenant adapter (operator-driven):** in Refinery Studio, create a tenant, create a
**Cloud** pool and **Deploy** it. The host controller fans the event to the in-cluster operator,
which creates the `CommunicationPool` CR + broker secret in `ns octo` and runs
`helm upgrade --install {tenantId}-{workload}` for each managed Adapter/Application. Verify:
```bash
kubectl --context kind-kind -n octo get communicationpool
kubectl --context kind-kind -n octo get pods
helm --kube-context kind-kind list -n octo
```

**Arbitrary application (demo-app) directly:**
```bash
helm --kube-context kind-kind upgrade --install demoapp \
  octo-helm-core/src/octo-mesh-demo-app -n octo \
  --values octo-helm-core/src/examples/demo-app-sample.yaml
kubectl --context kind-kind -n octo port-forward deploy/demoapp 8080:80
```

**Pulling from the dev registry (`docker.mm.cloud`):** `Install-OctoKubernetes` configures the
kind node's containerd to `skip_verify` TLS for the dev registry (its cert is signed by an
internal CA the node doesn't trust) via `kind-cluster.yaml`'s `containerdConfigPatches` +
`/etc/containerd/certs.d/<registry>/hosts.toml`. The registry is the `-DevRegistry` parameter
(default `docker.mm.cloud`; pass `""` to skip). With `operator.imageRegistry: docker.mm.cloud`
in `operator-dev-values.yaml`, adapters then pull `docker.mm.cloud/meshmakers/octo-mesh-adapter:<tag>`.

**Locally-built workload images:** set `image.privateRegistry=""`, `image.repository/tag` to
your local build with `pullPolicy: IfNotPresent`, then load it into the node:
```powershell
Import-OctoImageToKind -Image my-adapter:dev
```
(`Import-OctoImageToKind` uses `kind load`, and automatically falls back to `docker save | ctr import`
on hosts running Docker's containerd image store, where `kind load` produces an incomplete image.)

## Web exposure (ingress-nginx + cert-manager)

`Install-OctoKubernetes` installs **ingress-nginx** (class `nginx`, NodePort 30080/30443 mapped
to host 80/443 by `kind-cluster.yaml`) and **cert-manager** (jetstack), then applies a CA
`ClusterIssuer` named **`mm-cloud-issuer`** backed by a local self-signed root CA — the same
name/kind test-2/staging use, so an app's `ingress`/`publicUri` values copy over unchanged.
Pass `-SkipIngress` to skip it.

Apps are reached at **`https://<name>.localhost`** — `*.localhost` resolves to `127.0.0.1` in
browsers and the macOS resolver with no external service and no `/etc/hosts` edit. For Linux /
CLI tools that don't special-case `.localhost`, add `127.0.0.1 <name>.localhost` to `/etc/hosts`.

Expose a workload via the chart's ingress path (identical to staging):
```yaml
ingress:
  enabled: true
  className: nginx
  annotations:
    cert-manager.io/cluster-issuer: mm-cloud-issuer
publicUri: "https://<name>.localhost"
```

The local root CA (CN **"OctoMesh Local Dev Root CA"**, exported to
`infrastructure/local-root-ca.crt`) is **trusted automatically during setup** so browsers/tools
accept the certs without warnings (prompts for sudo on macOS/Linux; pass `-SkipTrustCa` for
unattended runs). The trust step is **idempotent** — re-running or recreating the cluster
replaces the entry rather than piling up duplicates:
```powershell
Add-OctoLocalCaTrust            # idempotent; Remove-OctoLocalCaTrust removes it
```
macOS adds it to the System keychain as a trusted root; Windows imports into
`Cert:\LocalMachine\Root`; Linux uses `update-ca-certificates`.

## Teardown

```powershell
Uninstall-OctoKubernetes      # deletes the kind cluster AND its data (Mongo/Crate PVCs)
```

To go back to the legacy docker-compose infra afterwards: `Start-OctoInfrastructure`.

## Backups

The kind infra uses `local-path` PVCs: data survives pod restarts but **not** `kind delete cluster`
(i.e. `Uninstall-OctoKubernetes`). There is no automated backup of the kind infra yet — for
durable data either keep the cluster, or `mongodump` / take a CrateDB snapshot before teardown.
The legacy `Manage-OctoInfrastructureBackup` (volume-tar) applies only to the docker-compose infra.

## Troubleshooting

- **`Install-OctoKubernetes` refuses immediately** — the docker-compose infra is running. Run
  `Stop-OctoInfrastructure` (or `docker stop mongo-0.mongo rabbitmq cratedb01 ...`).
- **Operator pod is Ready but pools show "Unregistered" / logs say "Cannot connect to controller"**
  — the host Communication Controller isn't running, or unreachable from the cluster. Start it via
  `Start-Octo`. The operator reaches it via the stable Docker host-gateway (`host.docker.internal`
  → e.g. `192.168.65.254`), which survives LAN/VPN/Tailscale IP changes; if your engine doesn't
  expose it, pass `-ControllerHost <reachable-ip>` to `Deploy-OctoOperator`.
  - **On Docker CE / Linux** the operator uses the kind bridge gateway (e.g. `172.18.0.1`)
    automatically. If it still can't connect after `Start-Octo`, check (a) the controller is
    listening on all interfaces — `ss -tlnp | grep 5015` should show `*:5015`, which `Start-Octo`
    does by default — and (b) a host firewall (ufw/firewalld) isn't dropping traffic from the kind
    bridge subnet to host port 5015 (Docker usually adds the allow rule; a locked-down host may
    need one for the `172.18.0.0/16` kind subnet → `:5015`).
- **Operator/adapter version mismatch** — the default published operator image
  (`3.3.108.0`) may not match a controller you built from this branch. If pool registration
  misbehaves, deploy a version-matched operator with `Deploy-OctoOperator -BuildLocal`.
- **Adapter pod `ImagePullBackOff` with `x509: certificate signed by unknown authority`** — the
  node doesn't trust the dev registry's internal CA. `Install-OctoKubernetes` configures
  `skip_verify` for `-DevRegistry` (default `docker.mm.cloud`); if you created the cluster before
  that change, just re-run `Install-OctoKubernetes` (it adds the certs.d config + restarts
  containerd if needed). Also make sure the registry is actually reachable (VPN) from the node.
- **`kind load` "content digest ... not found" / pod won't start with a locally-built image**
  — Docker's containerd image store breaks `kind load docker-image`. `Import-OctoImageToKind`
  already works around this; if you load images by hand, use
  `docker save <img> | docker exec -i kind-control-plane ctr --namespace=k8s.io images import --snapshotter=overlayfs -`.
- **Stale admission webhooks 500 on CR create** (after re-running the operator) — delete leftover
  configs: `kubectl delete validatingwebhookconfiguration communication-operator-validators --ignore-not-found`
  and the matching `mutatingwebhookconfiguration`.
- **CrateDB pod CrashLoops / "max virtual memory areas too low"** — the privileged init step
  sets `vm.max_map_count=262144` on the node; on some Docker backends it may need setting on the
  Docker VM itself.

## Notes on deviations from the original plan (discovered during implementation)

These were found by running every step on a real macOS / Docker 29 / Apple-Silicon machine:
- **Operator image:** pulled `meshmakers/octo-communication-operator:3.3.108.0` (no `latest` tag exists).
- **Webhook certs:** generated with **openssl** inside `Deploy-OctoOperator` (self-contained) rather
  than `octo-cli -c GenerateOperatorCertificates` (octo-cli need not be built).
- **`Get-HostLanIPv4`** falls back to interface enumeration because `GetHostAddresses(GetHostName())`
  throws on a Mac whose hostname isn't resolvable.
- **`Deploy-OctoOperator`** runs `helm dependency build`/`update` so it self-bootstraps on a fresh
  `octo-helm-core` checkout.
- **`Import-OctoImageToKind`** falls back to `docker save | ctr import` under the containerd image store.

### Windows (Docker Desktop) portability fixes

Verified end-to-end on Windows 11 / Docker Desktop 29 / PowerShell 7. The bring-up is identical
(`Install-OctoKubernetes` → `Deploy-OctoOperator` → `Invoke-BuildAll` → `Start-Octo` →
`Invoke-OctoCliLoginLocal`); these Windows-specific fixes were needed:
- **kind install:** `winget install Kubernetes.kind` (no Homebrew). winget updates the persisted
  user PATH but not already-running shells — restart the shell (or add
  `%LOCALAPPDATA%\Microsoft\WinGet\Packages\Kubernetes.kind_*\` to PATH) before running the cmdlets.
- **`Deploy-OctoOperator` — `helm --set-file` backslash escaping:** Helm's `--set`/`--set-file`
  parser treats `\` as an escape char, so a Windows temp cert path (`C:\Users\…\octo-operator-certs-…`)
  collapsed to `C:Users…` and the cert file wasn't found. Fixed by normalizing the temp cert dir to
  forward slashes (`$certDir -replace '\\','/'`) — accepted by helm/openssl/Remove-Item on all
  platforms, a no-op on macOS/Linux.
- **`Get-OctoKubernetesStatus` — host-port probe false negative:** Docker Desktop warms its
  published-port proxy lazily, so the first connect to a kind-mapped port can take >1s. The 800 ms
  `Test-HostPortOpen` timeout reported the (actually open) infra ports as "closed". Bumped to 2.5 s
  and added an `EndConnect`/`Connected` check so a refused port still reads correctly.
