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
  e.g. `192.168.65.254`) — a stable address that does *not* change with your LAN/VPN/Tailscale IP.
  **On Docker CE / Linux** the node has no `host.docker.internal` entry, so
  `Deploy-OctoOperator` falls back to the node's default-route gateway (the kind bridge gateway,
  e.g. `172.18.0.1`) — equally stable for the cluster's lifetime and routes to the host. For this
  to work the host services must listen on all interfaces (they bind `*:5015` etc., so they do).
- **Controller TLS — neither the operator nor the adapters have a bypass.** (The former
  `adapterIgnoreCertificateValidation` knob was a no-op — never projected into workloads, and no
  workload chart consumes it — and has been dropped from `operator-dev-values.yaml`, AB#5232.)
  Every in-cluster client validates the host's certificate, and locally that fails twice over: the
  host serves a self-signed ASP.NET dev certificate nothing in the cluster trusts, *and* the
  host-gateway address is not one of its SANs, so even trusting it leaves hostname validation
  failing. `Deploy-OctoOperator` handles both automatically — it reads the certificate off the
  running controller (by definition the one it will present) or, when the controller is not up
  (the normal case during `Install-OctoKubernetes`, which runs before `Start-Octo`), exports the
  same certificate from the local dev-cert store (`dotnet dev-certs https`, public part only).
  Either way it hands the PEM to the chart as `secrets.rootCa` and connects by a hostname the
  certificate actually names (`host.docker.internal` on a standard dev cert). It says which name
  and source it chose. Pass `-SkipControllerTlsTrust` where the controller already serves a
  trusted certificate.
- **Workload identity: trust + issuer both flow from the operator (AB#5232).** The operator
  projects `secrets.rootCa` into **every** workload it deploys (the adapter chart's trust
  initContainer splices it into `/etc/ssl/certs`), and `authUri` — the same SAN hostname as
  above, e.g. `https://host.docker.internal:5003` — becomes the adapter's
  `OCTO_ADAPTER__AUTHORITYURL`/`ISSUERURI`. Host-side callers (octo-cli, curl, E2E scripts) mint
  their tokens via `https://localhost:5003`, so those tokens carry issuer
  `https://localhost:5003/`; `operator-dev-values.yaml` therefore sets
  `operator.additionalValidIssuers: ["https://localhost:5003/"]`, which the operator projects as
  the workload's `additionalValidIssuers` (→ `OCTO_ADAPTER__ADDITIONALVALIDISSUERS__0`). Only the
  issuer string comparison is widened — signing keys still come from `authUri`'s discovery
  document. Requires an operator image with AB#5232 support; older images ignore the env var.
  Workloads deployed **before** the operator had correct values keep their old values until their
  next deploy (redeploy the workload, or bounce it via Studio).
- **That hostname has to resolve cluster-wide, not just in the operator pod.** The operator
  publishes its own `communicationControllerUri` into the Helm values of every workload it deploys
  (`WorkloadContextValuesBuilder`), so the name the operator connects by is also the name every
  adapter connects by — and adapter pods get no `hostAlias`. Left to normal DNS, a name like
  `mac.local` resolves through the host's mDNS to whichever interface answers first (a
  Parallels/VPN address in practice), which pods cannot reach; the adapters then sit at
  `Unregistered` forever while the operator itself is happily connected. `Deploy-OctoOperator`
  therefore adds a `hosts` block to **CoreDNS** mapping the name to the reachable address for the
  whole cluster (idempotent, marked `# octo-tools: controller alias`, with `fallthrough` so every
  other name resolves normally), in addition to the operator pod's own `hostAlias`.

### In-cluster DNS + host-port contract

| Component | In-cluster DNS | Host port |
|---|---|---|
| MongoDB | `mongodb-0.mongodb.octo-infra.svc.cluster.local:27017` (RS `rs`) | `localhost:27017` |
| RabbitMQ | `rabbitmq.octo-infra.svc.cluster.local:5672` | `localhost:5672` (AMQP) / `15672` (mgmt) |
| CrateDB | `cratedb.octo-infra.svc.cluster.local` (psql 5432 / http 4200) | `localhost:5432` (psql) / `4301` (http UI) |

There is exactly **one** CrateDB — host-run services and in-cluster adapters share it. The host
services connect as the built-in superuser `crate` (their compiled-in default), while deployed
adapters connect as the application user **`octo-system`** (injected by the operator from
`operator-dev-values.yaml`, mirroring the production octo-mesh chart). CrateDB's trust
authentication requires that user to *exist*, so `Install-OctoKubernetes` seeds it idempotently
after the CrateDB rollout (`Initialize-OctoKindCrateDbUser`: `CREATE USER "octo-system"` with the
password from `clusterSecrets.streamDataPassword` + `GRANT ALL PRIVILEGES`; an existing user is
left untouched). On a cluster created before this step existed, run
`Initialize-OctoKindCrateDbUser` once (or re-run `Install-OctoKubernetes`).

## Prerequisites

On PATH: `kind` (v0.31+), `kubectl`, `helm` (v3), `docker` (daemon running), `openssl`,
and `mongosh` (optional, for host verification). Install kind on macOS with `brew install kind`;
on **Windows** (Docker Desktop) with `winget install Kubernetes.kind` — then **restart your shell**
so `kind` resolves on PATH (winget updates the persisted user PATH, not running processes).
On **Linux** (Docker CE/Engine) there is no bundled installer — drop the `kind`/`kubectl`/`helm`
binaries on PATH manually (see QUICKSTART → Prerequisites; use the `arm64` URLs on ARM hosts).
The cmdlets run under `pwsh` on Linux exactly as on macOS/Windows. **PowerShell 7.4+** is
required — the dev-registry pre-flight uses `Test-Connection -TcpPort`, which was added in 7.4.
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
Install-OctoKubernetes
```

The Communication Operator is deployed by `Install-OctoKubernetes` itself, pulled from the dev
registry (`<registry.url>/meshmakers/octo-communication-operator:main-latest`, the rolling tag
CI publishes on every main build) — the same registry the adapter/app images come from. The
registry host comes from `registry.url` in your octo-tools config (`installations.json`); a
non-empty `image.privateRegistry` in `operator-dev-values.yaml` overrides it for this checkout.
`-SkipOperator` skips it. `Deploy-OctoOperator` is still available to (re)deploy it standalone:
- `-ImageTag <tag>` — operator image tag (default `main-latest`; pulled from the dev registry
  resolved as above).
- `-ControllerHost <ip>` — override the host address the operator/adapters use to reach the
  controller. By default the cmdlet uses the kind node's Docker host-gateway
  (`host.docker.internal`, e.g. `192.168.65.254`) — a **stable** address that does not change with
  your LAN/VPN/Tailscale IP. On Docker CE / Linux (no `host.docker.internal`) it auto-falls back to
  the kind bridge gateway (e.g. `172.18.0.1`), which is equally stable — so you normally don't need
  to override there either. Only pass this if neither is reachable (e.g. an unusual network setup).

**Network binding (LAN exposure).** By default the infra + ingress host ports bind to `127.0.0.1`
(loopback) — reachable from this machine only. To reach them from other machines on the LAN (e.g.
testing from a phone / another laptop), pass `Install-OctoKubernetes -ExposeLan`, which binds them
on `0.0.0.0`. ⚠️ This exposes MongoDB / CrateDB / RabbitMQ — which run with default dev credentials
(CrateDB auth-less) — to your whole network, so only use it on a trusted network. `-ExposeLan` only
takes effect when the cluster is created; recreate it (`Uninstall-OctoKubernetes` →
`Install-OctoKubernetes -ExposeLan`) to change the binding.

## Daily development

```powershell
# Build the backend (host processes), then start them. They connect to the kind infra
# on the same localhost ports as before — no config change needed.
Invoke-BuildAll -configuration DebugL -excludeFrontend $true
Start-Octo -configuration DebugL

# Authenticate the CLI
Register-OctoCliContext -Installation local -TenantId meshtest

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

**Pulling from the dev registry:** `Install-OctoKubernetes` configures the kind node's
containerd to `skip_verify` TLS for the dev registry (its cert is typically signed by an
internal CA the node doesn't trust) via `kind-cluster.yaml`'s `containerdConfigPatches` +
`/etc/containerd/certs.d/<registry>/hosts.toml`. The registry is the `-DevRegistry` parameter
(default: the `registry.url` value from your octo-tools config — see `installations.example.json`;
pass `""` to skip). `Deploy-OctoOperator` injects the same value as `operator.imageRegistry`,
so adapters then pull `<your-registry>/meshmakers/octo-mesh-adapter:<tag>`.

**Pre-loaded images (offline deploy):** pass `-SkipRegistryCheck` to `Deploy-OctoOperator`. It skips
the registry-resolves-from-the-node pre-flight and sets pull policy `IfNotPresent`, then loads the
image into the node yourself:
```powershell
Import-OctoImageToKind -Image my-adapter:dev
```
(`Import-OctoImageToKind` uses `kind load`, and automatically falls back to `docker save | ctr import`
on hosts running Docker's containerd image store, where `kind load` produces an incomplete image.)

Kubelet matches a pre-loaded image by its **full reference, registry prefix included** — a mismatch
is `ErrImageNeverPull`, not a fallback — and both shapes occur: an image pulled from the dev registry
and loaded keeps its `<registry>/meshmakers/...` prefix, a locally built one has none. So rather than
assuming either, the cmdlet asks the node which reference it actually holds and sets
`image.privateRegistry` to match, reporting its choice.

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

`Uninstall-OctoKubernetes` also removes the local root CA from the OS trust store (so no orphaned
"OctoMesh Local Dev Root CA" is left trusted after the cluster — whose private key it relied on — is
gone); pass `-KeepCaTrust` to leave it in place. To go back to the legacy docker-compose infra
afterwards: `Start-OctoInfrastructure`.

## Backups

The kind infra uses `local-path` PVCs: data survives pod restarts but **not** `kind delete cluster`
(i.e. `Uninstall-OctoKubernetes`). There is no automated backup of the kind infra yet — for
durable data either keep the cluster, or `mongodump` / take a CrateDB snapshot before teardown.
The legacy volume-tar backup cmdlets (`Backup-OctoInfrastructure` / `Restore-OctoInfrastructure`) apply only to the docker-compose infra.

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
- **Operator logs a TLS error against the controller** (`RemoteCertificateNameMismatch`,
  `RemoteCertificateChainErrors`, or "The SSL connection could not be established") — it validates
  that certificate and has no bypass, so the deploy has to wire trust up. With the dev-cert
  fallback this normally works even when the controller is down at deploy time; if it still
  failed (e.g. no .NET SDK on PATH, or Kestrel serves a non-default certificate), start the
  controller with `Start-Octo` and re-run `Deploy-OctoOperator`. Confirm the result on the pod —
  the spec should carry a `hostAliases` entry and `operator.communicationControllerUri` should use
  the certificate's hostname, not the raw gateway IP:
  `kubectl -n octo-operator-system get pod -o jsonpath='{.items[0].spec.hostAliases}'`.
- **Secured `FromHttpRequest` route answers 401 (`issuer_invalid`) or the adapter logs a TLS
  failure against identity** — the workload was deployed with stale identity values (raw gateway
  IP `authUri`, no `secrets.rootCa`, no `additionalValidIssuers`); typical for workloads deployed
  before the operator got the AB#5232 wiring. Re-run `Deploy-OctoOperator` (correct values +
  operator image), then redeploy the workload so it picks up the new context values. Verify on the
  pod: `OCTO_ADAPTER__AUTHORITYURL`/`ISSUERURI` should carry the certificate hostname
  (e.g. `https://host.docker.internal:5003`) and `OCTO_ADAPTER__ADDITIONALVALIDISSUERS__0` should
  be `https://localhost:5003/`.
- **Archive writes from a deployed adapter fail with `trust authentication failed for user
  "octo-system"`** — the CrateDB application user is missing (cluster created before the seeding
  step existed). Run `Initialize-OctoKindCrateDbUser` (idempotent), or re-run
  `Install-OctoKubernetes`. Host-run services are unaffected — they connect as `crate`.
- **Adapter deployed but stuck at `Unregistered`, operator itself connected** — the adapter pods
  got a controller address they cannot reach. Check what the deployment was actually given and
  whether it resolves to something reachable:
  `kubectl -n octo get deploy <release> -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="OCTO_ADAPTER__COMMUNICATIONCONTROLLERSERVICESURI")].value}'`,
  then from inside the cluster
  `kubectl -n octo run t --rm -i --restart=Never --image=curlimages/curl -- curl -sk -o /dev/null -w '%{http_code}' https://<name>:5015/`
  (a `404` means the controller answered — that is success here). Re-running
  `Deploy-OctoOperator` re-applies the CoreDNS alias.
- **Pod `ErrImagePull` with `no match for platform in manifest`** — the image has no build for the
  node's architecture (several adapter images ship `linux/amd64` only, and an Apple-Silicon kind
  node is `arm64`). Check with
  `docker manifest inspect <image>`. Docker Desktop on Apple Silicon registers **Rosetta** in the
  VM kernel (`/proc/sys/fs/binfmt_misc/rosetta`, flags include `F`), which kind nodes inherit, so
  the amd64 image does run once it is on the node — it just cannot be pulled. Load it by hand:
  ```bash
  docker pull --platform linux/amd64 <image>
  docker save --platform linux/amd64 <image> | \
    docker exec -i kind-control-plane ctr --namespace=k8s.io images import --digests --snapshotter=overlayfs --platform linux/amd64 -
  ```
  Both `--platform` flags matter: without the one on `docker save` the export carries no layers
  (an 856-byte index), and `ctr import` only takes native-platform content by default. `crictl
  images` will **not** list a foreign-arch image even when it is complete — verify with
  `ctr --namespace=k8s.io images check | grep <name>` (expect `complete`), and note the charts
  default to `pullPolicy: IfNotPresent`, so kubelet then uses it instead of pulling.
- **Operator pod `ErrImageNeverPull` after `-SkipRegistryCheck`** — the image on the node is under
  a different reference than the deploy asks for. List what the node actually holds with
  `docker exec kind-control-plane crictl images | grep operator` and load the missing reference
  (`Import-OctoImageToKind`); the prefix must match exactly.
- **Operator/adapter version mismatch** — the operator runs the dev registry's rolling
  `:main-latest` image, which may lag/lead a controller you built from this branch. If pool
  registration misbehaves, re-run `Deploy-OctoOperator` to pull the newest `:main-latest`.
- **Adapter pod `ImagePullBackOff` with `x509: certificate signed by unknown authority`** — the
  node doesn't trust the dev registry's internal CA. `Install-OctoKubernetes` configures
  `skip_verify` for `-DevRegistry` (default: `registry.url` from your octo-tools config); if you
  created the cluster before that change, just re-run `Install-OctoKubernetes` (it adds the
  certs.d config + restarts containerd if needed). Also make sure the registry is actually
  reachable (VPN) from the node.
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
- **Operator image:** pulled from the dev registry at `your-dev-registry.example.com/meshmakers/octo-communication-operator:main-latest` (rolling main-build tag).
- **Webhook certs:** generated with **openssl** inside `Deploy-OctoOperator` (self-contained) rather
  than `octo-cli -c GenerateOperatorCertificates` (octo-cli need not be built).
- **`Get-HostLanIPv4`** falls back to interface enumeration because `GetHostAddresses(GetHostName())`
  throws on a Mac whose hostname isn't resolvable.
- **`Deploy-OctoOperator`** runs `helm dependency build`/`update` so it self-bootstraps on a fresh
  `octo-helm-core` checkout.
- **`Import-OctoImageToKind`** falls back to `docker save | ctr import` under the containerd image store.

### Windows (Docker Desktop) portability fixes

Verified end-to-end on Windows 11 / Docker Desktop 29 / PowerShell 7.4+ (the dev-registry pre-flight uses `Test-Connection -TcpPort`, added in 7.4). The bring-up is identical
(`Install-OctoKubernetes` → `Deploy-OctoOperator` → `Invoke-BuildAll` → `Start-Octo` →
`Register-OctoCliContext -Installation local`); these Windows-specific fixes were needed:
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
