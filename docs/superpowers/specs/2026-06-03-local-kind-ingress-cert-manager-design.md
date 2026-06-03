# Local kind: ingress-nginx + cert-manager (staging-like web exposure)

**Date:** 2026-06-03
**Branch:** `dev/local-k8s-dev-env` (test-branch `octo-tools`)
**Status:** Design — awaiting review

## Goal

Make the local kind cluster (`Install-OctoKubernetes`) expose web workloads the
same way test-2 / staging do, so that an app's **exposure values are identical
across local and staging** and can be copied straight over. Concretely: install
**ingress-nginx** (class `nginx`) and **cert-manager** with a **CA `ClusterIssuer`
named `mm-cloud-issuer`**, matching the meshmakers cluster pattern.

## Context (what prod/staging actually run)

From `deployment/meshmakers-infrastructure` (RKE2 / k3s, Rancher-managed):

- Web exposure is **`Ingress` with `ingressClassName: nginx`** (ingress-nginx via
  the `kubernetes.github.io/ingress-nginx` Helm chart). There is **no Gateway API
  / HTTPRoute** anywhere in the infra — so the app charts' `httpRoute` path is not
  production-like and is out of scope.
- TLS via **cert-manager** (jetstack Helm chart). Apps annotate
  `cert-manager.io/cluster-issuer: mm-cloud-issuer`, where `mm-cloud-issuer` is a
  **CA-type `ClusterIssuer`** (a separate ACME/letsencrypt issuer exists for public
  prod certs — also out of scope locally).

The local cluster today (`Install-OctoKubernetes` in
`modules/Install-OctoInfrastructure.psm1`) creates the kind cluster, configures
containerd to pull from the dev registry, installs `octo-mesh-crds`, and applies
infra (mongo/rabbit/crate). It has **no ingress controller, no cert-manager, and
no 80/443 port mapping**.

## Non-goals

- Gateway API / HTTPRoute (prod doesn't use it).
- ACME / letsencrypt issuer (public-prod only; local uses a self-signed CA).
- HAProxy / LoadBalancer / external-dns (VM-cluster specifics).
- Switching the property-walker app to `ingress.enabled` — **infra only** this
  round; property-walker stays on `kubectl port-forward`.

## Architecture

Four additions, all living under `octo-tools/kubernetes/` and wired into
`Install-OctoKubernetes`:

1. **kind port mapping** — `kubernetes/kind-cluster.yaml` gains `extraPortMappings`
   `30080→80` and `30443→443` on `127.0.0.1`.
2. **ingress-nginx** — Helm install, class `nginx`, `service.type=NodePort` pinned
   to nodePorts `30080/30443` (the kind equivalent of staging's LoadBalancer
   install). Values in `kubernetes/ingress-nginx-values.yaml`.
3. **cert-manager + `mm-cloud-issuer`** — jetstack Helm install (+CRDs); a
   cert-manager self-signed **local root CA**, then a CA `ClusterIssuer` named
   `mm-cloud-issuer` backed by it. Values in `kubernetes/cert-manager-values.yaml`,
   issuers in `kubernetes/cluster-issuer.yaml`.
4. **`Install-OctoKubernetes` integration** — install steps run **on by default**,
   skippable with `-SkipIngress`; idempotent; correctly ordered (cert-manager
   ready before issuers).

### Hostname scheme

Apps use `*.localhost` hosts (e.g. `property-walker.localhost`). `*.localhost`
resolves to `127.0.0.1` via the macOS resolver and all major browsers with **no
external service and no `/etc/hosts` edits** (verified:
`dscacheutil -q host -a name property-walker.localhost` → `127.0.0.1`). For Linux
/ CLI tools that don't special-case `.localhost`, the install prints the one-line
`/etc/hosts` fallback (it does not edit `/etc/hosts` automatically).

### Local CA trust

The install exports the generated root CA to `infrastructure/local-root-ca.crt`
and prints the optional `security add-trusted-cert …` command (macOS) so the user
can trust it and avoid browser warnings. It does **not** modify the system
keychain automatically.

## Detailed design

### `kubernetes/kind-cluster.yaml`

Add to the `control-plane` node:

```yaml
    extraPortMappings:
      - { containerPort: 30080, hostPort: 80,  listenAddress: "127.0.0.1", protocol: TCP }  # ingress http
      - { containerPort: 30443, hostPort: 443, listenAddress: "127.0.0.1", protocol: TCP }  # ingress https
```

(Existing infra port mappings stay. No `ingress-ready` label needed — NodePort
routing, not hostPort.)

### `kubernetes/ingress-nginx-values.yaml`

```yaml
controller:
  ingressClassResource:
    name: nginx
    default: true
  ingressClass: nginx
  watchIngressWithoutClass: true
  service:
    type: NodePort
    nodePorts:
      http: 30080
      https: 30443
  # single-node kind: keep it light
  replicaCount: 1
```

Installed with `helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx
-n ingress-nginx --create-namespace -f kubernetes/ingress-nginx-values.yaml
--version <pinned>`. Chart version pinned to match staging (from
`meshmakers-infrastructure` group_vars; current stable is 4.11.x).

### `kubernetes/cert-manager-values.yaml`

```yaml
crds:
  enabled: true
replicaCount: 1
```

Installed with `helm upgrade --install cert-manager jetstack/cert-manager
-n cert-manager --create-namespace -f kubernetes/cert-manager-values.yaml
--version <pinned>`. Version pinned to match staging.

### `kubernetes/cluster-issuer.yaml`

```yaml
# 1) bootstrap self-signed issuer
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata: { name: selfsigned-bootstrap }
spec: { selfSigned: {} }
---
# 2) local root CA cert (stored in a secret in the cert-manager namespace)
apiVersion: cert-manager.io/v1
kind: Certificate
metadata: { name: local-root-ca, namespace: cert-manager }
spec:
  isCA: true
  commonName: octo-local-root-ca
  secretName: local-root-ca-tls
  duration: 87600h   # 10y
  privateKey: { algorithm: ECDSA, size: 256 }
  issuerRef: { name: selfsigned-bootstrap, kind: ClusterIssuer, group: cert-manager.io }
---
# 3) the CA ClusterIssuer named exactly as staging: mm-cloud-issuer
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata: { name: mm-cloud-issuer }
spec:
  ca: { secretName: local-root-ca-tls }
```

This yields a `mm-cloud-issuer` CA `ClusterIssuer` — same name and kind as
staging. App TLS certs are issued by the local root CA.

### `Install-OctoKubernetes` (in `Install-OctoInfrastructure.psm1`)

- New parameter: `[switch]$SkipIngress`.
- After the infra steps, when `-not $SkipIngress`:
  1. `helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx` and
     `helm repo add jetstack https://charts.jetstack.io` (idempotent), `helm repo update`.
  2. `helm upgrade --install ingress-nginx …` (values + pinned version).
  3. `helm upgrade --install cert-manager …` (CRDs + pinned version).
  4. Wait: `kubectl -n cert-manager rollout status deploy/cert-manager-webhook --timeout=180s`.
  5. `kubectl apply -f kubernetes/cluster-issuer.yaml`.
  6. Wait: `kubectl wait --for=condition=Ready clusterissuer/mm-cloud-issuer --timeout=120s`.
  7. Export CA: `kubectl get secret local-root-ca-tls -n cert-manager -o jsonpath='{.data.ca\.crt}'`
     → base64-decode → `infrastructure/local-root-ca.crt`; print the optional
     macOS trust command.
- All steps idempotent (`helm upgrade --install`, `kubectl apply`). Re-running the
  function leaves an existing setup healthy.
- Summary block extended with the ingress URL hint (`https://<app>.localhost`),
  the issuer name, and the exported CA path.

## How this mirrors staging (the payoff)

An app's exposure values are identical local vs staging:

```yaml
ingress:
  enabled: true
  className: nginx
  annotations:
    cert-manager.io/cluster-issuer: mm-cloud-issuer
publicUri: "https://<app>.localhost"   # only the host string differs per env
```

Only the CA *behind* `mm-cloud-issuer` differs (local self-signed root vs the
meshmakers internal CA) — an environment-level detail, not an app-level one. So
values developed locally copy to staging unchanged (swap the host).

## Verification

1. `kubectl get ingressclass nginx` exists; ingress-nginx controller `Running`.
2. cert-manager pods `Running`; `kubectl get clusterissuer mm-cloud-issuer` →
   `READY=True`.
3. Smoke test: apply a throwaway `http-echo`/`httpbin` Deployment + Service +
   Ingress (`host: echo.localhost`, TLS via `mm-cloud-issuer`); then
   `curl --cacert infrastructure/local-root-ca.crt https://echo.localhost` → 200,
   served cert chains to `octo-local-root-ca`. Tear it down.
4. Re-run `Install-OctoKubernetes` → no errors, no duplicate resources (idempotent).
5. `Install-OctoKubernetes -SkipIngress` → skips all of the above cleanly.

## Files

| Action | Path |
|---|---|
| Modify | `kubernetes/kind-cluster.yaml` (extraPortMappings 80/443) |
| Create | `kubernetes/ingress-nginx-values.yaml` |
| Create | `kubernetes/cert-manager-values.yaml` |
| Create | `kubernetes/cluster-issuer.yaml` |
| Modify | `modules/Install-OctoInfrastructure.psm1` (`Install-OctoKubernetes`: `-SkipIngress`, install steps, CA export, summary) |
| Modify | `kubernetes/QUICKSTART.md` / `kubernetes/README.md` (ingress + cert-manager usage, `*.localhost`, CA trust) |

## Open questions

- Exact chart versions to pin for ingress-nginx and cert-manager — take from
  `meshmakers-infrastructure` group_vars during implementation so local matches
  staging.
