# OctoMesh Local Kubernetes Dev Environment — Design Spec

- **Date:** 2026-05-30
- **Status:** Approved (design) — pending implementation plan
- **Author:** reimar + Claude
- **Primary repo touched:** `octo-tools` (cmdlets + infra manifests). Consumes `octo-helm-core` (CRDs + operator chart, already cloned next to the other repos).

---

## 1. Goal

Make local OctoMesh development easier by moving the **infrastructure** and the **adapter/application deployment mechanism** onto a local Kubernetes-in-Docker (kind) cluster, while keeping the core .NET services as host processes for fast edit/debug. This lets a developer exercise the **new Helm-based, operator-driven, per-tenant deployment of mesh-adapters and arbitrary applications** locally — the same mechanism used in the cloud — without standing up a full production-like cluster.

This is a **local development environment**, explicitly not a production clone (no multi-node, no redundancy, no HA).

## 2. Scope

### In scope (v1)

What runs **in the kind cluster**:
- **Infrastructure**, single-node: MongoDB (1-member replica set `rs`), RabbitMQ, CrateDB.
- **CRDs** (`octo-mesh-crds` from `octo-helm-core`).
- **Communication Operator** (`octo-mesh-communication-operator` from `octo-helm-core`), central mode.
- **Adapter / application pods** that the operator deploys per tenant via `helm upgrade --install`.

What stays **on the host** (unchanged from today):
- Core .NET services via `Start-Octo`: identity (5003), asset-repo (5001), communication-controller (5015), bot (5009).
- Frontends via `ng serve` (Refinery Studio, 4200).
- `octo-cli`.

The **net change vs. today**: docker-compose infra → kind-hosted infra; the operator runs in-cluster so the per-tenant Helm deployment flow works locally.

### Out of scope (v1 — explicitly deferred)

- The `octo-mesh` umbrella chart / running **core services in-cluster**. Core services stay host processes.
- `ingress-nginx` and `cert-manager`. Not required because no core HTTP service is exposed from the cluster in v1; inbound testing of HTTP-triggered adapter pipelines uses `kubectl port-forward`.
- Multi-node, replicas > 1, resource limits/quotas, production parity.
- Tilt / Skaffold / live-reload of in-cluster workloads.
- A redesigned backup/restore story for kind PVCs (noted as a follow-up; see §10).

## 3. Background (current state — summary)

- **Infra today:** `octo-tools/infrastructure/docker-compose.yml` — Mongo ×3 (RS `rs`, keyFile, host ports 27017/27018/27019), RabbitMQ 4.0.6 (5672/15672, guest/guest), CrateDB ×3 (HTTP 4301-4303, PG 5432-5434). Managed by `Install/Start/Stop-OctoInfrastructure`.
- **Services today:** host `dotnet` processes via `Start-Octo.psm1`, binding `https://localhost:50xx`, connecting to infra over `localhost` with infra hosts defaulted inside the Octo NuGet packages. `Start-Octo` already sets `OCTO_SYSTEM__USEDIRECTCONNECTION=true` (load-bearing for this design — see §6.1).
- **New deployment path:** `octo-communication-operator` (KubeOps) watches `CommunicationPool` CRs and runs `helm upgrade --install {tenantId}-{workload}` per Adapter/Application, pulling charts from a per-tenant configured Helm repo. CRDs + operator chart live in `octo-helm-core`. `Install-OctoKubernetes` (in `Install-OctoInfrastructure.psm1:184`) already creates a kind cluster + installs `octo-mesh-crds` + the `octo` namespace.

## 4. Target Architecture

```
┌──────────────────── HOST (macOS) ─────────────────────┐     ┌──────────── kind cluster (Docker) ─────────────┐
│ Start-Octo host processes (HTTPS, dev cert):           │     │ ns: octo-infra                                  │
│   identity 5003 · asset-repo 5001                      │     │   mongo (1-member RS "rs", keyFile)             │
│   communication-controller 5015 · bot 5009             │     │   rabbitmq · cratedb (single-node)              │
│ Frontends: Refinery Studio (ng serve, 4200)            │     │   exposed to host via NodePort+extraPortMappings│
│ octo-cli                                               │     │                                                 │
│                                                        │     │ ns: octo-operator-system                        │
│  ── connect to infra on localhost ───────────────────▶│ ──▶ │   CRDs + communication-operator (central mode)  │
│     27017 (mongo) · 5672 (rabbit) · 5432 (crate PG)    │     │                                                 │
│     4301 (crate HTTP) · 15672 (rabbit UI)              │     │ ns: octo                                        │
│                                                        │     │   adapter / application pods                     │
│  controller @ https://<host-LAN-IP>:5015 ◀────────────│ ◀── │   (helm-deployed per tenant by the operator)    │
│                                                        │     │   → broker/infra via in-cluster DNS             │
└────────────────────────────────────────────────────────┘     └─────────────────────────────────────────────────┘
        host → cluster: stable localhost ports (NodePort)
        cluster → host: host LAN IP (operator + adapter pods → controller :5015)
```

**Two directions of traffic, two mechanisms:**
- **Host → in-cluster infra:** the kind node publishes fixed host ports (NodePort + `extraPortMappings`) so host services keep using `localhost:<same-port-as-today>` with no config change.
- **Cluster → host controller:** the operator and adapter pods reach the host-process Communication Controller via the **host's LAN IP** (e.g. `https://192.168.x.y:5015`), auto-detected at deploy time (same approach the operator's existing DEBUG dev-webhook already uses). TLS validation against the host's `localhost` dev cert is bypassed via `AdapterIgnoreCertificateValidation`.

## 5. Components

### 5.1 kind cluster

- Single control-plane node (no workers). A **portable** kind config replaces the Salzburg-specific `octo-communication-operator/src/scripts/kind-cluster.yaml` (which references a private registry + a missing CA file and is not usable here).
- `extraPortMappings` publish the infra host ports listed in §4 from the node to `127.0.0.1` so host services reach them unchanged.
- Owned by `octo-tools` (new `octo-tools/kubernetes/kind-cluster.yaml`), driven by the cmdlets.

### 5.2 In-cluster infrastructure (`ns: octo-infra`)

Hand-written single-node manifests/templates that match the **current images** (no Bitnami dependency, to avoid the 2025 Bitnami catalog deprecation and stay faithful to what runs today). Each is a `StatefulSet` (or `Deployment` + PVC) + a `Service`, plus a `NodePort` for host exposure.

| Component | Image | In-cluster config | Host exposure | Persistence |
|---|---|---|---|---|
| MongoDB | `mongo:8.0.12` | `--replSet rs --keyFile … --bind_ip_all`, **single member**; RS initiated against the pod's own cluster DNS; admin/app users seeded | NodePort → `localhost:27017` | PVC (local-path) |
| RabbitMQ | `rabbitmq:4.0.6-management` | single instance, `guest/guest` | NodePort → `localhost:5672` + `15672` | ephemeral (matches today) |
| CrateDB | `crate:5.10.10` | single node: `-Cdiscovery.type=single-node` (replaces the 3-node quorum), `CRATE_HEAP_SIZE`, `vm.max_map_count` raised via a privileged init step on the node/pod | NodePort → `localhost:5432` (PG) + `4301` (HTTP UI) | PVC (local-path) |

**Mongo replica-set + keyFile (the known hard part) — chosen mitigations:**
- **keyFile ownership:** the keyFile is delivered as a `Secret`; an **initContainer** copies it into an `emptyDir` and `chmod 400` + `chown` to the mongod uid (999), which the main container mounts. (Secret mounts are root-owned/read-only and mongod refuses a key it cannot own — this sidesteps it.)
- **RS init + users:** reuse the existing `init-database.js` / `create-admin-user.js` (mounted via `ConfigMap`), adapted so the single RS member host is the pod's in-cluster DNS name, run from a post-start **Job** (or initContainer) via the localhost exception.
- **Dual reachability:** in-cluster clients (adapter pods) use the RS member's cluster DNS (discovery returns the same name → works). Host clients use `localhost:27017` with `directConnection=true` (already set by `Start-Octo`), bypassing RS member-hostname discovery. A 1-member RS still provides the transactions + change streams OctoMesh requires.

Credentials reuse today's dev values (`OctoAdmin1` / `OctoUser1`, `guest/guest`) so host-service expectations are unchanged.

### 5.3 CRDs + Operator (`ns: octo-operator-system`)

- **CRDs:** `helm install octo-mesh-crds ./octo-helm-core/src/octo-mesh-crds` (already done by `Install-OctoKubernetes`).
- **Operator:** `octo-helm-core/src/octo-mesh-communication-operator`, deployed with a **local dev values file** owned by `octo-tools`:
  - **Central mode** (`operator.autoManagePools=true`) so deploying a Cloud pool from Studio auto-creates the `CommunicationPool` CR + workload deploys (matches the E2E smoke test).
  - `CommunicationControllerUri = https://<host-LAN-IP>:5015` (auto-detected at deploy time).
  - `BrokerHost` = in-cluster rabbitmq Service DNS; broker user/pass = `guest/guest`.
  - `clusterDependencies.*` = in-cluster Mongo/Crate Service DNS (for adapters with `ReceivesClusterSecrets`).
  - `AdapterIgnoreCertificateValidation=true` (host controller serves a `localhost` dev cert; adapter pods reach it by IP).
  - **Webhook certs** generated via `octo-cli -c GenerateOperatorCertificates -o … -n octo-operator-system -s <release>-communication-operator` and passed as `--set-file serviceHooks.*` (no cert-manager).
  - Image: locally built `meshmakers/octo-communication-operator:dev`, `kind load`ed; `pullPolicy: IfNotPresent`.
- The operator pod runs `helm` against the in-cluster API using its ServiceAccount RBAC (provided by the chart).

### 5.4 Adapter / application deployment flow (`ns: octo`)

Unchanged operator behavior, now exercised locally:
1. Developer creates a tenant + a **Cloud** `Pool` and deploys it from Studio (or via `octo-cli`).
2. Controller (host) fans out pool/workload events over `/operatorHub` SignalR to the in-cluster operator.
3. Operator creates the CR + broker secret (`ns: octo`) and runs `helm repo add` + `helm upgrade --install {tenantId}-{workload}` for each Adapter/Application.
4. Adapter/app pods start in `ns: octo`, connect to in-cluster RabbitMQ/Mongo/Crate via cluster DNS and to the host controller via the host LAN IP.

- **Mesh-adapters:** chart from `octo-mesh-adapter` (or the per-tenant configured Helm repo). For locally built adapter images: `image.privateRegistry=""` + `image.repository/tag` + `kind load` (the chart already supports registry-less images).
- **Arbitrary applications:** the `octo-mesh-demo-app` chart (in `octo-helm-core`) is the reference pattern; any Helm chart reachable from the tenant's configured Helm repository can be deployed the same way.

## 6. Host ↔ Cluster wiring

### 6.1 Host → in-cluster infra
NodePort Services + kind `extraPortMappings` pin the **same host ports used today** (27017 / 5672 / 5432 / 4301 / 15672) to `127.0.0.1`. Host services therefore connect with **no config change**. `OCTO_SYSTEM__USEDIRECTCONNECTION=true` (already set by `Start-Octo`) makes the Mongo driver talk directly to `localhost:27017` without resolving RS member cluster-DNS names.

### 6.2 Cluster → host controller
Operator + adapter pods use the host's LAN IP (`https://<host-LAN-IP>:5015`). The deploy cmdlet auto-detects the first non-loopback IPv4 (consistent with the operator's existing dev-webhook logic) and bakes it into the operator values; an override (`-ControllerHost`) is provided for VPN/multi-NIC hosts. TLS mismatch (dev cert is for `localhost`) is tolerated via `AdapterIgnoreCertificateValidation=true`.

## 7. Cmdlet surface (`octo-tools`)

Extend the existing PowerShell tooling (no new external tool):

| Cmdlet | Responsibility |
|---|---|
| `Install-OctoKubernetes` (extend) | Create kind cluster from the new portable config; install CRDs; install **in-cluster infra** (`octo-infra`); create `octo` namespace. Idempotent. |
| `Deploy-OctoOperator` (new) | Build + `kind load` the operator image; generate webhook certs; `helm upgrade --install` the operator with the local dev values + auto-detected host IP. |
| `Build-OctoImages` / `Import-OctoImages` (new, or fold into existing build) | Build adapter/app/operator images and `kind load` them for local deployment. |
| `Start-Octo` (adjust) | Unchanged process model; ensure host services target the kind infra (same localhost ports — likely zero change). Gate so it does not also start docker-compose infra. |
| `Get-OctoKubernetesStatus` (new) | `kubectl get` across `octo-infra` / `octo-operator-system` / `octo` + infra reachability check from host. |
| `Uninstall-OctoKubernetes` (new) | `kind delete cluster` (+ warn about PVC data loss). |

**Coexistence guard:** the kind infra and the docker-compose infra use the **same host ports** and cannot run simultaneously. The cmdlets detect a running docker-compose infra and refuse / offer to stop it (and vice versa). docker-compose remains available as a fallback.

## 8. Repo layout

```
octo-tools/
  kubernetes/
    kind-cluster.yaml              # portable kind config (extraPortMappings)
    infra/                         # single-node Mongo/RabbitMQ/CrateDB manifests (or a small chart)
      mongo.yaml  rabbitmq.yaml  cratedb.yaml  (+ ConfigMaps for the mongo init scripts)
    operator-dev-values.yaml       # local dev values for octo-mesh-communication-operator
  modules/
    Install-OctoInfrastructure.psm1  # Install-OctoKubernetes extended here (existing location)
    Deploy-OctoOperator.psm1         # new
    Get-OctoKubernetesStatus.psm1    # new
    Uninstall-OctoKubernetes.psm1    # new
  docs/superpowers/specs/2026-05-30-octomesh-local-k8s-infra-design.md  # this doc
octo-helm-core/                    # consumed as-is (CRDs, operator chart, demo-app); cloned next to repos
```

Dev-only infra manifests live in `octo-tools` (the dev-tooling repo) rather than `octo-helm-core`, keeping the production chart repo clean (prod uses external/managed infra).

## 9. Secrets & certificates

- **Mongo keyFile:** generated once (reuse `Install-OctoInfrastructure`'s 741-byte base64 routine), stored as a k8s `Secret`, permission-fixed via initContainer (§5.2).
- **DB / broker creds:** dev values (`OctoAdmin1`, `OctoUser1`, `guest/guest`) as k8s Secrets, matching host-service expectations.
- **Operator webhook certs:** `octo-cli -c GenerateOperatorCertificates` → `--set-file serviceHooks.*`.
- **Identity signing key / license keys:** **not needed in-cluster in v1** (identity runs on the host).
- **rootCa / dev CA:** only needed if adapter pods must trust the host controller's TLS — bypassed via `AdapterIgnoreCertificateValidation=true` in v1; `secrets.rootCa` remains available if stricter TLS is wanted later.

## 10. Data & backup

- Infra PVCs use kind's `local-path` provisioner — data survives **pod restarts** but **not** `kind delete cluster`.
- The existing cold-`tar`-the-docker-volume backup (`Manage-OctoInfrastructureBackup`) does not apply to PVCs. v1 leaves backups to a follow-up (mongodump / Crate snapshot / `kubectl cp`). Acceptable for a dev environment; called out as a known gap.

## 11. Failure modes & mitigations

| Risk | Mitigation |
|---|---|
| Mongo refuses keyFile (perms/ownership) | initContainer copy + `chmod 400` + `chown 999` (§5.2) |
| Mongo RS not initiated → no transactions/change streams | post-start Job runs `rs.initiate` (single member) + waits for primary |
| Host client can't resolve RS member cluster-DNS | `directConnection=true` (already set) + NodePort `localhost:27017` |
| CrateDB won't bootstrap as 1 node | `discovery.type=single-node`; raise `vm.max_map_count` via privileged init |
| Port conflict with running docker-compose infra | coexistence guard in cmdlets (§7) |
| Cluster→host controller unreachable (VPN/multi-NIC) | auto-detected host LAN IP + `-ControllerHost` override |
| Adapter TLS validation fails against `localhost` dev cert | `AdapterIgnoreCertificateValidation=true` |
| Locally built image not found in cluster | `kind load` + `pullPolicy: IfNotPresent`; avoid `:latest` |
| Apple-Silicon arch mismatch (`exec format error`) | infra images are multi-arch; build service images for arm64 |

## 12. Validation / acceptance

v1 is "done" when, on a clean machine:
1. `Install-OctoKubernetes` brings up kind + infra + CRDs; `Get-OctoKubernetesStatus` shows all infra Ready and reachable from the host on the expected localhost ports.
2. `Start-Octo` runs the host services against the kind infra; identity/asset-repo/controller/bot come up healthy and `octo-cli -c AuthStatus` works.
3. `Deploy-OctoOperator` installs the operator (Ready, webhooks registered).
4. From Studio/CLI: create a tenant + Cloud pool → deploy → a **mesh-adapter** pod appears in `ns: octo` (`helm list -n octo`), connects to the controller, and a simple pipeline executes.
5. The **demo-app** (arbitrary application) deploys the same way and is reachable via `kubectl port-forward`.
6. `Uninstall-OctoKubernetes` tears it all down.

## 13. Open questions (resolve during planning)

- Exact host ports/protocol each service uses for CrateDB (PG 5432 vs HTTP) — pin from appsettings/package defaults during the plan.
- Whether to package the infra as raw manifests applied by the cmdlet or as a tiny local Helm chart (leaning: raw manifests/kustomize for transparency; revisit if templating grows).
- Whether `Start-Octo` needs any env change at all, or the existing `localhost` defaults already line up 1:1 with the NodePort exposure (expected: no change).
