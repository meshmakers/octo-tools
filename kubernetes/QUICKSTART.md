# OctoMesh Local kind Dev Environment — Quick Start

From-scratch setup for the local **kind**-based OctoMesh dev environment. Infrastructure
(MongoDB / RabbitMQ / CrateDB), the CRDs and the Communication Operator run **in the cluster**;
the four core .NET services (identity / asset-repo / communication-controller / bot) and the
frontends stay **host processes**. Everything below runs in **PowerShell (`pwsh`)** from your
monorepo workspace root. All cmdlets are idempotent — re-running is safe.

> Full runbook + troubleshooting: [`README.md`](./README.md).

---

## 0 · Prerequisites (once)

**Tools on PATH:** `kind` (v0.31+) · `kubectl` · `helm` v3 · `docker` (daemon running) · `openssl`
(`mongosh` optional, for host-side verification).

```powershell
brew install kind        # kubectl / helm / openssl are usually already installed
```

**Repos:** `octo-helm-core` must be checked out **next to** the other repos (it ships the CRDs +
operator chart). It is a **sibling** of `octo-tools` in your workspace:

```powershell
# from your monorepo workspace root (the folder that already contains octo-tools/)
git clone git@github.com:meshmakers/octo-helm-core.git
```

**Branch:** the kind scripts currently live on the feature branch — switch `octo-tools` to it:

```powershell
git -C ./octo-tools switch dev/local-k8s-dev-env
```

**Dev registry:** `docker.mm.cloud` must be reachable (VPN) so the cluster can pull adapter images.
`Install-OctoKubernetes` configures the node to trust it automatically.

---

## 1 · Stop the legacy docker-compose infra

The kind infra binds the **same** host ports (27017/5672/15672/5432/4301) as the old
`Start-OctoInfrastructure` stack — they cannot run together. `Install-OctoKubernetes` refuses to
run while the compose containers are up.

```powershell
Stop-OctoInfrastructure
```

---

## 2 · Bring up the cluster

```powershell
# Cluster + CRDs + namespaces + in-cluster infra (mongo/rabbit/crate) + Mongo RS init.
# Also configures the node to trust the docker.mm.cloud dev registry.
Install-OctoKubernetes

# Deploy the Communication Operator (central mode). Generates webhook certs, pulls the
# published image, and wires it to your host controller via host.docker.internal.
Deploy-OctoOperator
```

---

## 3 · Build + start the host services

They connect to the kind infra on the same `localhost` ports as before — no config change.

```powershell
Invoke-BuildAll -configuration DebugL -excludeFrontend $true
Start-Octo -configuration DebugL        # ⚠ blocks this terminal until you stop the services
```

In a **second** `pwsh`, authenticate the CLI:

```powershell
Invoke-OctoCliLoginLocal
```

---

## 4 · Verify

```powershell
Get-OctoKubernetesStatus
```

You should have: a kind cluster (one Docker container) running Mongo / RabbitMQ / CrateDB +
the CRDs + the operator, with `identity:5003`, `asset-repo:5001`, `communication-controller:5015`,
`bot:5009` running natively on the host.

---

## 5 · Deploy an adapter

In **Refinery Studio**: create a tenant → create a **Cloud** pool → **Deploy** it. Set the
adapter's **Chart Version** to a published build (e.g. `0.1.260531002`) and `image.tag`
(e.g. `main-latest`). The host controller fans the event to the in-cluster operator, which
`helm upgrade --install`s the adapter into `ns:octo`. Verify:

```powershell
kubectl --context kind-kind -n octo get communicationpool
kubectl --context kind-kind -n octo get pods
```

---

## Teardown

```powershell
Uninstall-OctoKubernetes          # deletes the kind cluster AND its data (Mongo/Crate PVCs)
Start-OctoInfrastructure          # (optional) go back to the legacy docker-compose infra
```

---

## If something's off

| Symptom | Fix |
|---|---|
| `Install-OctoKubernetes` refuses immediately | docker-compose infra still running → `Stop-OctoInfrastructure` |
| Operator Ready but pools "Unregistered" | host controller not running → `Start-Octo` |
| Adapter `ImagePullBackOff` · `x509: certificate signed by unknown authority` | not on VPN, or node doesn't trust the dev registry → check VPN, re-run `Install-OctoKubernetes` |
| Adapter install `improper constraint: main-latest` | `main-latest` is an image tag, not a chart version → set a real **Chart Version** in Studio |

See [`README.md`](./README.md) → *Troubleshooting* for the full list.
