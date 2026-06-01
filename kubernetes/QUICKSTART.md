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
# macOS (kubectl / helm / openssl are usually already installed)
brew install kind

# Windows (Docker Desktop). winget puts kind in %LOCALAPPDATA%\Microsoft\WinGet\Packages\...
winget install Kubernetes.kind
```

> **Windows:** after `winget install`, **restart your shell** (or open a new `pwsh`) so `kind`
> resolves on PATH — winget updates the persisted user PATH but not already-running processes.
> Verify with `kind version`.

> **Linux (Docker CE / Engine):** there is no bundled installer — drop the three binaries on
> PATH (use `arm64` instead of `amd64` on Apple-Silicon/ARM hosts). The cmdlets run under `pwsh`
> on Linux just like macOS/Windows.
> ```bash
> # kind
> curl -fsSLo kind https://kind.sigs.k8s.io/dl/v0.31.0/kind-linux-amd64
> chmod +x kind && sudo mv kind /usr/local/bin/kind
> # kubectl
> curl -fsSLo kubectl "https://dl.k8s.io/release/$(curl -fsSL https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
> chmod +x kubectl && sudo mv kubectl /usr/local/bin/kubectl
> # helm
> curl -fsSL https://get.helm.sh/helm-v3.16.4-linux-amd64.tar.gz | tar -xz
> sudo mv linux-amd64/helm /usr/local/bin/helm && rm -rf linux-amd64
> ```

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
| Windows: `kind` / cmdlet says *"kind is not on PATH"* right after `winget install` | winget didn't update the running shell → restart `pwsh` (or add `%LOCALAPPDATA%\Microsoft\WinGet\Packages\Kubernetes.kind_*\` to PATH), then `kind version` |
| Windows: `Get-OctoKubernetesStatus` shows host ports `closed` but infra pods are Running | Docker Desktop's port-proxy first-connect lag (fixed: probe now waits 2.5s). Confirm with `kind get clusters` + `docker port kind-control-plane`; the ports are mapped to `127.0.0.1` |
| Operator Ready but pools "Unregistered" | host controller not running → `Start-Octo` |
| Adapter `ImagePullBackOff` · `x509: certificate signed by unknown authority` | not on VPN, or node doesn't trust the dev registry → check VPN, re-run `Install-OctoKubernetes` |

See [`README.md`](./README.md) → *Troubleshooting* for the full list.
