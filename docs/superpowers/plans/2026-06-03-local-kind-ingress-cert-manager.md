# Local kind ingress-nginx + cert-manager Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the local kind cluster staging-like web exposure — ingress-nginx (class `nginx`) + cert-manager with a CA `ClusterIssuer` named `mm-cloud-issuer` — so app exposure values copy to staging unchanged.

**Architecture:** Add Helm-installed ingress-nginx (NodePort 30080/30443, mapped to host 80/443 by kind) and jetstack cert-manager, plus a cert-manager self-signed local root CA fronted by a CA `ClusterIssuer` named `mm-cloud-issuer`. Wire it into `Install-OctoKubernetes` (on by default, `-SkipIngress` to opt out). Manifests/values live under `octo-tools/kubernetes/`.

**Tech Stack:** kind, Helm 3, ingress-nginx chart `4.15.1`, cert-manager `v1.20.2`, PowerShell, `*.localhost` hostnames.

**Spec:** `docs/superpowers/specs/2026-06-03-local-kind-ingress-cert-manager-design.md`

**Preconditions:** a running kind cluster (context `kind-kind`) with `kubectl`, `helm`, `kind` on PATH. Tasks 1–3 and 5 install into the *existing* cluster so they're testable immediately; Task 4 (kind port-mapping) only takes effect on the next `kind create`, so it's verified by recreation in Task 8.

---

### Task 1: ingress-nginx values + install

**Files:**
- Create: `kubernetes/ingress-nginx-values.yaml`
- Test: manual (kubectl/helm)

- [ ] **Step 1: Create the values file**

`kubernetes/ingress-nginx-values.yaml`:
```yaml
# ingress-nginx for the local kind cluster. NodePort 30080/30443 are mapped to
# host 80/443 by kubernetes/kind-cluster.yaml. Mirrors staging (chart 4.15.1,
# class "nginx") with NodePort instead of LoadBalancer.
controller:
  ingressClassResource:
    name: nginx
    enabled: true
    default: true
  ingressClass: nginx
  watchIngressWithoutClass: true
  replicaCount: 1
  service:
    type: NodePort
    nodePorts:
      http: 30080
      https: 30443
  admissionWebhooks:
    enabled: true
```

- [ ] **Step 2: Add the helm repo**

Run:
```bash
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update ingress-nginx
```
Expected: `"ingress-nginx" has been added` / `Update Complete`.

- [ ] **Step 3: Install into the running cluster**

Run:
```bash
helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  --kube-context kind-kind \
  --namespace ingress-nginx --create-namespace \
  --version 4.15.1 \
  -f kubernetes/ingress-nginx-values.yaml \
  --wait --timeout 180s
```
Expected: `STATUS: deployed`.

- [ ] **Step 4: Verify controller + class**

Run:
```bash
kubectl --context kind-kind -n ingress-nginx get deploy ingress-nginx-controller
kubectl --context kind-kind get ingressclass nginx
```
Expected: deployment `1/1` READY; an `ingressclass.networking.k8s.io/nginx` row exists.

- [ ] **Step 5: Commit**

```bash
git add kubernetes/ingress-nginx-values.yaml
git commit -m "feat(k8s): ingress-nginx values for local kind cluster"
```

---

### Task 2: cert-manager values + install

**Files:**
- Create: `kubernetes/cert-manager-values.yaml`
- Test: manual (kubectl/helm)

- [ ] **Step 1: Create the values file**

`kubernetes/cert-manager-values.yaml`:
```yaml
# cert-manager for the local kind cluster (jetstack chart v1.20.2). CRDs are
# installed by the chart so no separate kubectl apply of cert-manager.crds.yaml
# is needed.
crds:
  enabled: true
replicaCount: 1
```

- [ ] **Step 2: Add the helm repo**

Run:
```bash
helm repo add jetstack https://charts.jetstack.io
helm repo update jetstack
```
Expected: `"jetstack" has been added` / `Update Complete`.

- [ ] **Step 3: Install into the running cluster**

Run:
```bash
helm upgrade --install cert-manager jetstack/cert-manager \
  --kube-context kind-kind \
  --namespace cert-manager --create-namespace \
  --version v1.20.2 \
  -f kubernetes/cert-manager-values.yaml \
  --wait --timeout 180s
```
Expected: `STATUS: deployed`.

- [ ] **Step 4: Verify pods + webhook**

Run:
```bash
kubectl --context kind-kind -n cert-manager rollout status deploy/cert-manager-webhook --timeout=120s
kubectl --context kind-kind -n cert-manager get deploy
```
Expected: `deployment "cert-manager-webhook" successfully rolled out`; `cert-manager`, `cert-manager-cainjector`, `cert-manager-webhook` all `1/1`.

- [ ] **Step 5: Commit**

```bash
git add kubernetes/cert-manager-values.yaml
git commit -m "feat(k8s): cert-manager values for local kind cluster"
```

---

### Task 3: mm-cloud-issuer (local root CA)

**Files:**
- Create: `kubernetes/cluster-issuer.yaml`
- Test: manual (kubectl)

- [ ] **Step 1: Create the issuer manifest**

`kubernetes/cluster-issuer.yaml`:
```yaml
# Local self-signed root CA fronted by a CA ClusterIssuer named exactly as
# staging (mm-cloud-issuer), so app annotations are identical across envs.
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: selfsigned-bootstrap
spec:
  selfSigned: {}
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: local-root-ca
  namespace: cert-manager
spec:
  isCA: true
  commonName: octo-local-root-ca
  secretName: local-root-ca-tls
  duration: 87600h          # 10 years
  privateKey:
    algorithm: ECDSA
    size: 256
  issuerRef:
    name: selfsigned-bootstrap
    kind: ClusterIssuer
    group: cert-manager.io
---
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: mm-cloud-issuer
spec:
  ca:
    secretName: local-root-ca-tls
```

- [ ] **Step 2: Apply it**

Run:
```bash
kubectl --context kind-kind apply -f kubernetes/cluster-issuer.yaml
```
Expected: `clusterissuer.../selfsigned-bootstrap created`, `certificate.../local-root-ca created`, `clusterissuer.../mm-cloud-issuer created`.

- [ ] **Step 3: Verify the issuer is Ready**

Run:
```bash
kubectl --context kind-kind wait --for=condition=Ready clusterissuer/mm-cloud-issuer --timeout=120s
kubectl --context kind-kind get clusterissuer mm-cloud-issuer
```
Expected: `clusterissuer.cert-manager.io/mm-cloud-issuer condition met`; `READY True`.

- [ ] **Step 4: Commit**

```bash
git add kubernetes/cluster-issuer.yaml
git commit -m "feat(k8s): mm-cloud-issuer CA ClusterIssuer (local root CA)"
```

---

### Task 4: kind port mappings for 80/443

**Files:**
- Modify: `kubernetes/kind-cluster.yaml`

- [ ] **Step 1: Add the http/https extraPortMappings**

In `kubernetes/kind-cluster.yaml`, under the `control-plane` node's
`extraPortMappings:` list, append (keep the existing infra mappings):
```yaml
      - { containerPort: 30080, hostPort: 80,  listenAddress: "127.0.0.1", protocol: TCP }  # ingress http
      - { containerPort: 30443, hostPort: 443, listenAddress: "127.0.0.1", protocol: TCP }  # ingress https
```

- [ ] **Step 2: Validate YAML**

Run:
```bash
python3 -c "import yaml; yaml.safe_load(open('kubernetes/kind-cluster.yaml')); print('ok')"
```
Expected: `ok`.

- [ ] **Step 3: Commit**

```bash
git add kubernetes/kind-cluster.yaml
git commit -m "feat(k8s): map kind 30080/30443 to host 80/443 for ingress"
```

> Note: this only affects clusters created *after* this change. The running
> cluster is exercised via port-forward in Task 5; full host-port routing is
> verified after recreation in Task 8.

---

### Task 5: End-to-end smoke test (throwaway)

**Files:**
- Create (temporary, deleted at end): `/tmp/echo-smoke.yaml`
- Test: curl over TLS

- [ ] **Step 1: Write the smoke manifest**

`/tmp/echo-smoke.yaml`:
```yaml
apiVersion: apps/v1
kind: Deployment
metadata: { name: echo, namespace: default }
spec:
  replicas: 1
  selector: { matchLabels: { app: echo } }
  template:
    metadata: { labels: { app: echo } }
    spec:
      containers:
        - name: echo
          image: hashicorp/http-echo:1.0
          args: ["-text=hello-from-ingress", "-listen=:5678"]
          ports: [{ containerPort: 5678 }]
---
apiVersion: v1
kind: Service
metadata: { name: echo, namespace: default }
spec:
  selector: { app: echo }
  ports: [{ port: 80, targetPort: 5678 }]
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: echo
  namespace: default
  annotations:
    cert-manager.io/cluster-issuer: mm-cloud-issuer
spec:
  ingressClassName: nginx
  tls:
    - hosts: [echo.localhost]
      secretName: echo-tls
  rules:
    - host: echo.localhost
      http:
        paths:
          - path: /
            pathType: Prefix
            backend: { service: { name: echo, port: { number: 80 } } }
```

- [ ] **Step 2: Apply and wait for the cert**

Run:
```bash
kubectl --context kind-kind apply -f /tmp/echo-smoke.yaml
kubectl --context kind-kind wait --for=condition=Ready certificate/echo-tls --timeout=120s
```
Expected: `certificate.cert-manager.io/echo-tls condition met`.

- [ ] **Step 3: Export the local root CA and curl over TLS**

Run (port-forward avoids depending on the not-yet-applied kind 80/443 mapping):
```bash
kubectl --context kind-kind get secret local-root-ca-tls -n cert-manager \
  -o jsonpath='{.data.ca\.crt}' | base64 -d > /tmp/local-root-ca.crt
kubectl --context kind-kind -n ingress-nginx port-forward svc/ingress-nginx-controller 8443:443 >/tmp/pf.log 2>&1 &
PF=$!; sleep 3
curl -s --cacert /tmp/local-root-ca.crt --resolve echo.localhost:8443:127.0.0.1 https://echo.localhost:8443/
kill $PF
```
Expected: `hello-from-ingress` (TLS verified against the local root CA — proves ingress routing + mm-cloud-issuer issuance work).

- [ ] **Step 4: Tear down the smoke resources**

Run:
```bash
kubectl --context kind-kind delete -f /tmp/echo-smoke.yaml
rm -f /tmp/echo-smoke.yaml /tmp/local-root-ca.crt /tmp/pf.log
```
Expected: resources deleted.

- [ ] **Step 5: Commit (no code change — checkpoint only)**

No files changed in this task; skip commit. Record the smoke result in the PR/notes.

---

### Task 6: Wire into Install-OctoKubernetes

**Files:**
- Modify: `modules/Install-OctoInfrastructure.psm1` (function `Install-OctoKubernetes`)

- [ ] **Step 1: Add the `-SkipIngress` parameter**

In the `param(...)` block of `Install-OctoKubernetes` (alongside `$SkipInfra`), add:
```powershell
        [Parameter()] [switch]$SkipIngress,
```

- [ ] **Step 2: Add the install block**

Immediately *after* the `namespaces.yaml` apply (the block that ends the infra
section, around the `if (-not $SkipInfra)` close), insert:
```powershell
    if (-not $SkipIngress) {
        $ctx = "kind-$ClusterName"
        Write-Progress -Activity 'Install Octo Kubernetes' -Status 'Installing ingress-nginx + cert-manager' -PercentComplete 90

        & helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx 2>$null
        & helm repo add jetstack https://charts.jetstack.io 2>$null
        & helm repo update ingress-nginx jetstack | Out-Null

        Write-Host "Installing ingress-nginx (4.15.1)" -ForegroundColor Green
        & helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx `
            --kube-context $ctx --namespace ingress-nginx --create-namespace `
            --version 4.15.1 -f (Join-Path $k8sDir "ingress-nginx-values.yaml") --wait --timeout 180s
        if ($LASTEXITCODE -ne 0) { Write-Error "ingress-nginx install failed"; return }

        Write-Host "Installing cert-manager (v1.20.2)" -ForegroundColor Green
        & helm upgrade --install cert-manager jetstack/cert-manager `
            --kube-context $ctx --namespace cert-manager --create-namespace `
            --version v1.20.2 -f (Join-Path $k8sDir "cert-manager-values.yaml") --wait --timeout 180s
        if ($LASTEXITCODE -ne 0) { Write-Error "cert-manager install failed"; return }

        & kubectl --context $ctx -n cert-manager rollout status deploy/cert-manager-webhook --timeout=120s

        Write-Host "Applying mm-cloud-issuer (local root CA)" -ForegroundColor Green
        & kubectl --context $ctx apply -f (Join-Path $k8sDir "cluster-issuer.yaml")
        if ($LASTEXITCODE -ne 0) { Write-Error "cluster-issuer apply failed"; return }
        & kubectl --context $ctx wait --for=condition=Ready clusterissuer/mm-cloud-issuer --timeout=120s

        # Export the root CA for optional host trust.
        $caPath = Join-Path $infrastructurePath "local-root-ca.crt"
        $caB64 = (& kubectl --context $ctx get secret local-root-ca-tls -n cert-manager -o "jsonpath={.data.ca\.crt}")
        if ($caB64) {
            [IO.File]::WriteAllBytes($caPath, [Convert]::FromBase64String($caB64))
            Write-Host "Local root CA written to $caPath" -ForegroundColor Cyan
            Write-Host "  To trust it (macOS): sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain `"$caPath`"" -ForegroundColor Yellow
        }
    }
```

- [ ] **Step 3: Extend the summary block**

In the final summary `Write-Host` section, after the CRDs line, add:
```powershell
    if (-not $SkipIngress) {
        Write-Host "  Ingress:           ingress-nginx (class 'nginx'), https://<app>.localhost" -ForegroundColor Cyan
        Write-Host "  TLS issuer:        mm-cloud-issuer (local root CA)" -ForegroundColor Cyan
    }
```

- [ ] **Step 4: Verify idempotency on the running cluster**

Run (PowerShell):
```bash
pwsh -NoProfile -Command ". ./modules/Install-OctoInfrastructure.psm1; Install-OctoKubernetes -SkipInfra"
```
Expected: ingress-nginx + cert-manager report `deployed`, `mm-cloud-issuer condition met`, CA written, no errors (re-run is a no-op upgrade).

- [ ] **Step 5: Verify `-SkipIngress` skips cleanly**

Run:
```bash
pwsh -NoProfile -Command ". ./modules/Install-OctoInfrastructure.psm1; Install-OctoKubernetes -SkipInfra -SkipIngress"
```
Expected: completes without touching ingress-nginx/cert-manager.

- [ ] **Step 6: Commit**

```bash
git add modules/Install-OctoInfrastructure.psm1
git commit -m "feat(k8s): install ingress-nginx + cert-manager in Install-OctoKubernetes (-SkipIngress to opt out)"
```

---

### Task 7: Docs

**Files:**
- Modify: `kubernetes/QUICKSTART.md`
- Modify: `kubernetes/README.md`

- [ ] **Step 1: Document the new behaviour**

Add a section to both files covering: ingress-nginx (class `nginx`) + cert-manager are installed by default (`-SkipIngress` to skip); apps are reached at `https://<name>.localhost` (resolves to 127.0.0.1, no `/etc/hosts` needed; Linux/CLI fallback: add `127.0.0.1 <name>.localhost` to `/etc/hosts`); TLS via `mm-cloud-issuer`; the root CA is exported to `infrastructure/local-root-ca.crt` and the macOS trust command is printed. Note that app `ingress`/`publicUri` values match staging and copy over unchanged.

- [ ] **Step 2: Commit**

```bash
git add kubernetes/QUICKSTART.md kubernetes/README.md
git commit -m "docs(k8s): document ingress-nginx + cert-manager local setup"
```

---

### Task 8: Full recreate verification

**Files:** none (verification only)

- [ ] **Step 1: Recreate the cluster from scratch**

> Destructive: deletes the local cluster. Confirm with the user before running.

Run:
```bash
kind delete cluster --name kind
pwsh -NoProfile -Command ". ./modules/Install-OctoInfrastructure.psm1; Install-OctoKubernetes"
```
Expected: cluster created with 80/443 mappings, infra + ingress-nginx + cert-manager + mm-cloud-issuer all installed, CA exported.

- [ ] **Step 2: Verify host-port routing (no port-forward)**

Run:
```bash
kubectl --context kind-kind apply -f /tmp/echo-smoke.yaml   # recreate from Task 5 manifest
kubectl --context kind-kind wait --for=condition=Ready certificate/echo-tls --timeout=120s
curl -s --cacert infrastructure/local-root-ca.crt https://echo.localhost/
kubectl --context kind-kind delete -f /tmp/echo-smoke.yaml
```
Expected: `hello-from-ingress` over `https://echo.localhost` on host port 443 directly (proves the kind 80/443 mapping + `*.localhost` + mm-cloud-issuer all work end-to-end).

- [ ] **Step 3: No commit (verification only)**

---

## Self-Review

- **Spec coverage:** kind mappings (Task 4/8), ingress-nginx (1), cert-manager (2), mm-cloud-issuer CA (3), Install-OctoKubernetes integration + `-SkipIngress` + CA export (6), `*.localhost` + docs (7), verification incl. idempotency and recreate (5/6/8). App-switch is correctly out of scope. ✔
- **Placeholders:** none — all YAML/commands are concrete; versions pinned (4.15.1 / v1.20.2). ✔
- **Consistency:** issuer name `mm-cloud-issuer`, secret `local-root-ca-tls`, namespaces `ingress-nginx`/`cert-manager`, CA path `infrastructure/local-root-ca.crt`, nodePorts 30080/30443 ↔ host 80/443 used consistently across tasks. ✔
