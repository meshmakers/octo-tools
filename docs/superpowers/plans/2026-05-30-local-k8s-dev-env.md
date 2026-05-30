# OctoMesh Local Kubernetes Dev Environment — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Run OctoMesh infrastructure (Mongo / RabbitMQ / CrateDB, single-node) plus the CRDs and the Communication Operator inside a local `kind` cluster, while the core .NET services keep running as host processes — so a developer can exercise the Helm-/operator-driven per-tenant adapter & application deployment locally.

**Architecture:** Single-node infra runs as k8s manifests in `ns: octo-infra`, exposed to host processes on the **same localhost ports used today** (27017/5672/15672/5432/4301) via kind `extraPortMappings` + NodePort Services. The operator runs in `ns: octo-operator-system` (central mode), reaches the host controller via the auto-detected host LAN IP, and deploys workloads into `ns: octo`. PowerShell cmdlets in `octo-tools` orchestrate everything; the existing `Start-Octo` host processes are unchanged (they already use `USEDIRECTCONNECTION=true` + localhost defaults).

**Tech Stack:** kind, kubectl, helm, Docker; Kubernetes manifests (YAML); PowerShell (`octo-tools/modules`); `octo-helm-core` charts (`octo-mesh-crds`, `octo-mesh-communication-operator`, `octo-mesh-demo-app`); `octo-cli` (`GenerateOperatorCertificates`).

> **Verification model.** This is infrastructure/tooling work, not unit-testable application code, so each task's "test" is a concrete **verification command with expected output** run against a real cluster, followed by a commit. Run PowerShell cmdlets by dot-sourcing the profile: `pwsh -NoProfile -c '. ./octo-tools/modules/profile.ps1; <cmd>'` (per `~/.claude/CLAUDE.md`, do not chain shell commands with `&&`/`;` — run each in its own invocation). Work happens on the existing branch `dev/local-k8s-dev-env` in `octo-tools`.

---

## File Structure

All new files live in `octo-tools` unless noted. `octo-helm-core` is consumed as-is.

| File | Responsibility |
|---|---|
| `octo-tools/kubernetes/kind-cluster.yaml` | Portable kind config: 1 control-plane node + `extraPortMappings` pinning infra host ports |
| `octo-tools/kubernetes/namespaces.yaml` | `octo-infra`, `octo`, `octo-operator-system` namespaces |
| `octo-tools/kubernetes/infra/rabbitmq.yaml` | RabbitMQ Deployment + NodePort Service |
| `octo-tools/kubernetes/infra/cratedb.yaml` | CrateDB single-node StatefulSet + headless Service + NodePort Service |
| `octo-tools/kubernetes/infra/mongodb.yaml` | MongoDB StatefulSet (keyFile init-container) + headless Service + NodePort Service |
| `octo-tools/kubernetes/infra/mongo-init/init-replicaset.js` | Single-member `rs.initiate` against in-cluster DNS |
| `octo-tools/kubernetes/infra/mongo-init/create-admin-user.js` | Seed `octo-system-admin` root user (copied from existing) |
| `octo-tools/kubernetes/operator-dev-values.yaml` | Local dev values for `octo-mesh-communication-operator` |
| `octo-tools/modules/Install-OctoInfrastructure.psm1` (modify) | Extend `Install-OctoKubernetes`: kind config, namespaces, infra, Mongo init, coexistence guard |
| `octo-tools/modules/Import-OctoImageToKind.psm1` (create) | Build/tag a local image and `kind load` it |
| `octo-tools/modules/Deploy-OctoOperator.psm1` (create) | Webhook certs + host-IP detection + `helm upgrade --install` operator |
| `octo-tools/modules/Get-OctoKubernetesStatus.psm1` (create) | Pods/helm/host-port status across the 3 namespaces |
| `octo-tools/modules/Uninstall-OctoKubernetes.psm1` (create) | `kind delete cluster` (+ data-loss warning) |
| `octo-tools/modules/profile.ps1` (modify) | Register new modules + `$kubernetesPath` global |
| `octo-tools/kubernetes/README.md` (create) | Runbook: bring-up, smoke test, teardown, troubleshooting |

**In-cluster DNS + port contract** (used throughout):
- Mongo: pod `mongodb-0.mongodb.octo-infra.svc.cluster.local:27017`, RS name `rs`; host `localhost:27017` (nodePort 30017).
- RabbitMQ: `rabbitmq.octo-infra.svc.cluster.local:5672`; host `localhost:5672` (30672) + `15672` (31672); guest/guest.
- CrateDB: `cratedb.octo-infra.svc.cluster.local` (psql 5432 / http 4200); host `localhost:5432` (30543) + `localhost:4301` (30420).

---

## Task 1: kind cluster config + namespaces

**Files:**
- Create: `octo-tools/kubernetes/kind-cluster.yaml`
- Create: `octo-tools/kubernetes/namespaces.yaml`

- [ ] **Step 1: Write the kind cluster config**

`octo-tools/kubernetes/kind-cluster.yaml`:
```yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: kind
nodes:
  - role: control-plane
    extraPortMappings:
      - { containerPort: 30017, hostPort: 27017, listenAddress: "127.0.0.1", protocol: TCP }  # mongodb
      - { containerPort: 30672, hostPort: 5672,  listenAddress: "127.0.0.1", protocol: TCP }  # rabbitmq amqp
      - { containerPort: 31672, hostPort: 15672, listenAddress: "127.0.0.1", protocol: TCP }  # rabbitmq mgmt
      - { containerPort: 30543, hostPort: 5432,  listenAddress: "127.0.0.1", protocol: TCP }  # cratedb psql
      - { containerPort: 30420, hostPort: 4301,  listenAddress: "127.0.0.1", protocol: TCP }  # cratedb http
```

- [ ] **Step 2: Write the namespaces manifest**

`octo-tools/kubernetes/namespaces.yaml`:
```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: octo-infra
---
apiVersion: v1
kind: Namespace
metadata:
  name: octo
---
apiVersion: v1
kind: Namespace
metadata:
  name: octo-operator-system
```

- [ ] **Step 3: Verify the kind config creates a cluster with the port mappings**

Run (separate invocations):
```bash
kind create cluster --config octo-tools/kubernetes/kind-cluster.yaml --name kind
kubectl --context kind-kind apply -f octo-tools/kubernetes/namespaces.yaml
docker port kind-control-plane
kubectl --context kind-kind get ns octo-infra octo octo-operator-system
```
Expected: cluster creates without error; `docker port` lists `27017`, `5672`, `15672`, `5432`, `4301` bound to `127.0.0.1`; all three namespaces show `Active`.

- [ ] **Step 4: Tear the probe cluster back down (infra tasks recreate it)**

Run: `kind delete cluster --name kind`
Expected: `Deleting cluster "kind" ...` with exit code 0.

- [ ] **Step 5: Commit**

```bash
git -C octo-tools add kubernetes/kind-cluster.yaml kubernetes/namespaces.yaml
git -C octo-tools commit -m "Add kind cluster config + namespaces for local k8s dev env"
```

---

## Task 2: RabbitMQ manifest

Simplest infra component — validates the NodePort + `extraPortMappings` host-port pattern end-to-end before the harder stateful components.

**Files:**
- Create: `octo-tools/kubernetes/infra/rabbitmq.yaml`

- [ ] **Step 1: Write the RabbitMQ manifest**

`octo-tools/kubernetes/infra/rabbitmq.yaml`:
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: rabbitmq
  namespace: octo-infra
  labels: { app: rabbitmq }
spec:
  replicas: 1
  selector: { matchLabels: { app: rabbitmq } }
  template:
    metadata: { labels: { app: rabbitmq } }
    spec:
      containers:
        - name: rabbitmq
          image: rabbitmq:4.0.6-management
          env:
            - { name: RABBITMQ_DEFAULT_USER, value: "guest" }
            - { name: RABBITMQ_DEFAULT_PASS, value: "guest" }
          ports:
            - { containerPort: 5672,  name: amqp }
            - { containerPort: 15672, name: management }
          readinessProbe:
            exec: { command: ["rabbitmq-diagnostics", "-q", "ping"] }
            initialDelaySeconds: 15
            periodSeconds: 10
---
apiVersion: v1
kind: Service
metadata:
  name: rabbitmq
  namespace: octo-infra
spec:
  type: NodePort
  selector: { app: rabbitmq }
  ports:
    - { name: amqp,       port: 5672,  targetPort: 5672,  nodePort: 30672 }
    - { name: management, port: 15672, targetPort: 15672, nodePort: 31672 }
```

- [ ] **Step 2: Bring up a cluster and apply it**

Run (separate invocations):
```bash
kind create cluster --config octo-tools/kubernetes/kind-cluster.yaml --name kind
kubectl --context kind-kind apply -f octo-tools/kubernetes/namespaces.yaml
kubectl --context kind-kind apply -f octo-tools/kubernetes/infra/rabbitmq.yaml
kubectl --context kind-kind -n octo-infra rollout status deploy/rabbitmq --timeout=120s
```
Expected: `deployment "rabbitmq" successfully rolled out`.

- [ ] **Step 3: Verify host reachability on the mapped ports**

Run: `curl -s -u guest:guest http://localhost:15672/api/overview`
Expected: JSON containing `"product_name":"RabbitMQ"`. (AMQP port: `nc -z localhost 5672` returns success.)

- [ ] **Step 4: Commit**

```bash
git -C octo-tools add kubernetes/infra/rabbitmq.yaml
git -C octo-tools commit -m "Add single-instance RabbitMQ manifest for local k8s infra"
```

---

## Task 3: CrateDB single-node manifest

**Files:**
- Create: `octo-tools/kubernetes/infra/cratedb.yaml`

- [ ] **Step 1: Write the CrateDB manifest**

`octo-tools/kubernetes/infra/cratedb.yaml`:
```yaml
apiVersion: v1
kind: Service
metadata:
  name: cratedb
  namespace: octo-infra
  labels: { app: cratedb }
spec:
  clusterIP: None
  selector: { app: cratedb }
  ports:
    - { name: http, port: 4200, targetPort: 4200 }
    - { name: psql, port: 5432, targetPort: 5432 }
---
apiVersion: v1
kind: Service
metadata:
  name: cratedb-ext
  namespace: octo-infra
spec:
  type: NodePort
  selector: { app: cratedb }
  ports:
    - { name: http, port: 4200, targetPort: 4200, nodePort: 30420 }
    - { name: psql, port: 5432, targetPort: 5432, nodePort: 30543 }
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: cratedb
  namespace: octo-infra
spec:
  serviceName: cratedb
  replicas: 1
  selector: { matchLabels: { app: cratedb } }
  template:
    metadata: { labels: { app: cratedb } }
    spec:
      initContainers:
        - name: sysctl
          image: busybox:1.36
          command: ["sh", "-c", "sysctl -w vm.max_map_count=262144"]
          securityContext: { privileged: true }
      containers:
        - name: cratedb
          image: crate:5.10.10
          args:
            - "crate"
            - "-Cdiscovery.type=single-node"
            - "-Cnetwork.host=0.0.0.0"
            - "-Cnode.name=cratedb01"
            - "-Cpath.repo=/data/backup"
          env:
            - { name: CRATE_HEAP_SIZE, value: "2g" }
          ports:
            - { containerPort: 4200, name: http }
            - { containerPort: 5432, name: psql }
          volumeMounts:
            - { name: data, mountPath: /data }
          readinessProbe:
            httpGet: { path: "/", port: 4200 }
            initialDelaySeconds: 20
            periodSeconds: 10
  volumeClaimTemplates:
    - metadata: { name: data }
      spec:
        accessModes: ["ReadWriteOnce"]
        resources: { requests: { storage: 5Gi } }
```

- [ ] **Step 2: Apply it to the running cluster**

Run (separate invocations):
```bash
kubectl --context kind-kind apply -f octo-tools/kubernetes/infra/cratedb.yaml
kubectl --context kind-kind -n octo-infra rollout status statefulset/cratedb --timeout=180s
```
Expected: `statefulset rolling update complete 1 pods at revision ...`.

- [ ] **Step 3: Verify host reachability + single-node health**

Run: `curl -s http://localhost:4301/ `
Expected: JSON with `"name":"cratedb01"` and `"cluster_name"`. (PG port: `nc -z localhost 5432` succeeds.)

- [ ] **Step 4: Commit**

```bash
git -C octo-tools add kubernetes/infra/cratedb.yaml
git -C octo-tools commit -m "Add single-node CrateDB StatefulSet for local k8s infra"
```

---

## Task 4: MongoDB manifest + single-member replica-set init scripts

The hardest component: keyFile auth (ownership), single-member RS, and admin-user seeding that must run from inside the pod (localhost exception).

**Files:**
- Create: `octo-tools/kubernetes/infra/mongo-init/init-replicaset.js`
- Create: `octo-tools/kubernetes/infra/mongo-init/create-admin-user.js`
- Create: `octo-tools/kubernetes/infra/mongodb.yaml`

- [ ] **Step 1: Write the single-member replica-set init script**

`octo-tools/kubernetes/infra/mongo-init/init-replicaset.js`:
```javascript
var cfg = {
    "_id": "rs",
    "version": 1,
    "members": [
        {
            "_id": 0,
            "host": "mongodb-0.mongodb.octo-infra.svc.cluster.local:27017",
            "priority": 1
        }
    ]
};

rs.initiate(cfg, { force: true });
console.log('Waiting for replica set to initialize!');
while (true) {
    const status = rs.status();
    if (status.myState == 1) {
        console.log('Replica set fully initialized!');
        break;
    }
    sleep(2000);
}
```

- [ ] **Step 2: Write the admin-user script (identical creds to docker-compose)**

`octo-tools/kubernetes/infra/mongo-init/create-admin-user.js`:
```javascript
admin = db.getSiblingDB("admin");
admin.createUser(
  {
    user: "octo-system-admin",
     pwd: "OctoAdmin1",
     roles: [ { role: "root", db: "admin" } ]
  });
admin.auth("octo-system-admin", "OctoAdmin1");
```

- [ ] **Step 3: Write the MongoDB manifest (keyFile init-container + RS)**

`octo-tools/kubernetes/infra/mongodb.yaml`:
```yaml
apiVersion: v1
kind: Service
metadata:
  name: mongodb
  namespace: octo-infra
  labels: { app: mongodb }
spec:
  clusterIP: None
  selector: { app: mongodb }
  ports:
    - { name: mongo, port: 27017, targetPort: 27017 }
---
apiVersion: v1
kind: Service
metadata:
  name: mongodb-ext
  namespace: octo-infra
spec:
  type: NodePort
  selector: { app: mongodb }
  ports:
    - { name: mongo, port: 27017, targetPort: 27017, nodePort: 30017 }
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: mongodb
  namespace: octo-infra
spec:
  serviceName: mongodb
  replicas: 1
  selector: { matchLabels: { app: mongodb } }
  template:
    metadata: { labels: { app: mongodb } }
    spec:
      securityContext:
        runAsUser: 999
        runAsGroup: 999
        fsGroup: 999
      initContainers:
        - name: copy-keyfile
          image: mongo:8.0.12
          command:
            - "sh"
            - "-c"
            - "cp /secret/file.key /keyfile/file.key && chmod 400 /keyfile/file.key && chown 999:999 /keyfile/file.key"
          securityContext: { runAsUser: 0 }
          volumeMounts:
            - { name: keyfile-secret, mountPath: /secret, readOnly: true }
            - { name: keyfile, mountPath: /keyfile }
      containers:
        - name: mongodb
          image: mongo:8.0.12
          command:
            - "mongod"
            - "--keyFile"
            - "/keyfile/file.key"
            - "--replSet"
            - "rs"
            - "--bind_ip_all"
            - "--wiredTigerCacheSizeGB"
            - "2"
          ports:
            - { containerPort: 27017, name: mongo }
          volumeMounts:
            - { name: keyfile, mountPath: /keyfile }
            - { name: data, mountPath: /data/db }
            - { name: init, mountPath: /scripts }
          readinessProbe:
            exec:
              command: ["sh", "-c", "mongosh --quiet --eval 'db.adminCommand({ ping: 1 })'"]
            initialDelaySeconds: 10
            periodSeconds: 10
      volumes:
        - { name: keyfile-secret, secret: { secretName: mongodb-keyfile } }
        - { name: keyfile, emptyDir: {} }
        - { name: init, configMap: { name: mongodb-init } }
  volumeClaimTemplates:
    - metadata: { name: data }
      spec:
        accessModes: ["ReadWriteOnce"]
        resources: { requests: { storage: 5Gi } }
```

- [ ] **Step 4: Manually create the keyFile secret + init configmap, apply, init the RS**

(These commands are automated by `Install-OctoKubernetes` in Task 5; here we run them by hand to verify the manifest + init flow.)

Run (separate invocations):
```bash
head -c 741 /dev/urandom | base64 | tr -d '\n' > /tmp/file.key
kubectl --context kind-kind -n octo-infra create secret generic mongodb-keyfile --from-file=file.key=/tmp/file.key
kubectl --context kind-kind -n octo-infra create configmap mongodb-init --from-file=octo-tools/kubernetes/infra/mongo-init/
kubectl --context kind-kind apply -f octo-tools/kubernetes/infra/mongodb.yaml
kubectl --context kind-kind -n octo-infra rollout status statefulset/mongodb --timeout=180s
kubectl --context kind-kind -n octo-infra exec mongodb-0 -- mongosh admin /scripts/init-replicaset.js
kubectl --context kind-kind -n octo-infra exec mongodb-0 -- mongosh admin /scripts/create-admin-user.js
```
Expected: rollout completes; init prints `Replica set fully initialized!`; admin script prints `{ ok: 1 }`-style success with no auth error.

- [ ] **Step 5: Verify the RS is primary and reachable from the host with directConnection**

Run: `mongosh "mongodb://octo-system-admin:OctoAdmin1@localhost:27017/admin?directConnection=true" --quiet --eval "rs.status().myState"`
Expected: prints `1` (PRIMARY). (If `mongosh` is not on the host, run the same `--eval` via `kubectl ... exec mongodb-0 -- mongosh "mongodb://localhost:27017/admin?directConnection=true"`.)

- [ ] **Step 6: Commit**

```bash
git -C octo-tools add kubernetes/infra/mongodb.yaml kubernetes/infra/mongo-init/
git -C octo-tools commit -m "Add single-member MongoDB replica set manifest + init scripts for local k8s infra"
```

---

## Task 5: Extend `Install-OctoKubernetes` to provision infra + guard coexistence

Make the one cmdlet bring up the whole in-cluster infra idempotently: kind (with config), namespaces, CRDs (existing), keyFile secret, init configmap, infra manifests, Mongo RS init, with a guard against the docker-compose infra running on the same host ports.

**Files:**
- Modify: `octo-tools/modules/Install-OctoInfrastructure.psm1` (the `Install-OctoKubernetes` function, lines 184-319, + a helper)

- [ ] **Step 1: Add a coexistence-guard helper above `Install-OctoKubernetes`**

Insert before `function Install-OctoKubernetes {` (around line 184):
```powershell
function Test-DockerComposeInfraRunning {
    # Returns $true if any of the docker-compose infra containers are running,
    # which would collide on host ports 27017/5672/5432 with the kind infra.
    $names = @("mongo-0.mongo", "rabbitmq", "cratedb01")
    $running = docker ps --format '{{.Names}}' 2>$null
    foreach ($n in $names) {
        if ($running -contains $n) { return $true }
    }
    return $false
}
```

- [ ] **Step 2: Add the infra parameters + coexistence guard to `Install-OctoKubernetes`**

In the `param(...)` block of `Install-OctoKubernetes` add:
```powershell
        [Parameter()] [string]$InfraNamespace = "octo-infra",
        [Parameter()] [switch]$SkipInfra
```
Immediately after the existing `foreach ($tool in @("kind", "helm", "kubectl"))` tool-check loop, add `docker` to the tool list and insert the guard:
```powershell
    if (-not $SkipInfra -and (Test-DockerComposeInfraRunning)) {
        Write-Error "docker-compose infrastructure is running and will collide on host ports 27017/5672/5432. Run 'Stop-OctoInfrastructure' first, or pass -SkipInfra to install only the k8s control plane."
        return
    }
```
Change the tool list line to: `foreach ($tool in @("kind", "helm", "kubectl", "docker")) {`.

- [ ] **Step 3: Use the kind config when creating the cluster**

Replace the cluster-create branch (currently `& kind create cluster --name $ClusterName`) with:
```powershell
        $kindConfig = Join-Path $branchRootPath "octo-tools/kubernetes/kind-cluster.yaml"
        if (!(Test-Path $kindConfig)) {
            Write-Error "kind config not found at $kindConfig"
            return
        }
        Write-Host "Creating kind cluster '$ClusterName' from $kindConfig" -ForegroundColor Green
        & kind create cluster --name $ClusterName --config $kindConfig
        if ($LASTEXITCODE -ne 0) {
            Write-Error "kind create cluster failed with exit code $LASTEXITCODE"
            return
        }
```

- [ ] **Step 4: Apply namespaces from the manifest (replace ad-hoc `octo` ns creation)**

After the CRDs `helm upgrade --install` block and before the final status print, replace the `$PoolNamespace` create block with:
```powershell
    $k8sDir = Join-Path $branchRootPath "octo-tools/kubernetes"
    Write-Host "Applying namespaces" -ForegroundColor Green
    & kubectl --context "kind-$ClusterName" apply -f (Join-Path $k8sDir "namespaces.yaml")
    if ($LASTEXITCODE -ne 0) { Write-Error "kubectl apply namespaces failed"; return }
```

- [ ] **Step 5: Add the infra bring-up block (keyFile secret, init configmap, manifests, Mongo RS init)**

After the namespaces apply, before the status print, add:
```powershell
    if (-not $SkipInfra) {
        $ctx = "kind-$ClusterName"
        $infraDir = Join-Path $k8sDir "infra"

        # 1) keyFile secret (generate once; reuse infrastructure/file.key if present)
        $keyFile = Join-Path $infrastructurePath "file.key"
        if (!(Test-Path $keyFile)) {
            Write-Host "Generating Mongo keyFile" -ForegroundColor Green
            $randBytes = New-Object byte[] 741
            [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($randBytes)
            [Convert]::ToBase64String($randBytes) > $keyFile
        }
        & kubectl --context $ctx -n $InfraNamespace delete secret mongodb-keyfile --ignore-not-found | Out-Null
        & kubectl --context $ctx -n $InfraNamespace create secret generic mongodb-keyfile --from-file=file.key=$keyFile
        if ($LASTEXITCODE -ne 0) { Write-Error "create mongodb-keyfile secret failed"; return }

        # 2) Mongo init scripts configmap
        & kubectl --context $ctx -n $InfraNamespace delete configmap mongodb-init --ignore-not-found | Out-Null
        & kubectl --context $ctx -n $InfraNamespace create configmap mongodb-init --from-file=(Join-Path $infraDir "mongo-init")
        if ($LASTEXITCODE -ne 0) { Write-Error "create mongodb-init configmap failed"; return }

        # 3) Apply infra workloads
        foreach ($m in @("rabbitmq.yaml", "cratedb.yaml", "mongodb.yaml")) {
            & kubectl --context $ctx apply -f (Join-Path $infraDir $m)
            if ($LASTEXITCODE -ne 0) { Write-Error "kubectl apply $m failed"; return }
        }

        # 4) Wait for readiness
        Write-Host "Waiting for infra to become ready..." -ForegroundColor Green
        & kubectl --context $ctx -n $InfraNamespace rollout status deploy/rabbitmq --timeout=180s
        & kubectl --context $ctx -n $InfraNamespace rollout status statefulset/cratedb --timeout=300s
        & kubectl --context $ctx -n $InfraNamespace rollout status statefulset/mongodb --timeout=300s

        # 5) Initialize the replica set (retry on transient network error), then seed admin user
        Write-Host "Initializing Mongo replica set" -ForegroundColor Green
        while ($true) {
            & { & kubectl --context $ctx -n $InfraNamespace exec mongodb-0 -- mongosh admin /scripts/init-replicaset.js } 2>k8s-stderr.txt
            $err = Get-Content k8s-stderr.txt -Raw
            Write-Host $err
            if ((-not [string]::IsNullOrWhiteSpace($err)) -and ($err -match "MongoNetworkError|not running|ECONNREFUSED")) {
                Start-Sleep -s 3
                continue
            }
            Remove-Item k8s-stderr.txt -ErrorAction SilentlyContinue
            break
        }
        & kubectl --context $ctx -n $InfraNamespace exec mongodb-0 -- mongosh admin /scripts/create-admin-user.js
    }
```

- [ ] **Step 6: Verify the full bring-up from a clean state**

Run (separate invocations):
```bash
kind delete cluster --name kind
pwsh -NoProfile -c '. ./octo-tools/modules/profile.ps1; Install-OctoKubernetes'
kubectl --context kind-kind -n octo-infra get pods
curl -s http://localhost:4301/
mongosh "mongodb://octo-system-admin:OctoAdmin1@localhost:27017/admin?directConnection=true" --quiet --eval "rs.status().myState"
```
Expected: all `octo-infra` pods `Running`/`Ready`; Crate JSON returned; Mongo prints `1`.

- [ ] **Step 7: Verify the coexistence guard**

Run (separate invocations):
```bash
pwsh -NoProfile -c '. ./octo-tools/modules/profile.ps1; Start-OctoInfrastructure'
pwsh -NoProfile -c '. ./octo-tools/modules/profile.ps1; Install-OctoKubernetes'
pwsh -NoProfile -c '. ./octo-tools/modules/profile.ps1; Stop-OctoInfrastructure'
```
Expected: the middle command errors with the "docker-compose infrastructure is running …" message and does not create a cluster.

- [ ] **Step 8: Commit**

```bash
git -C octo-tools add modules/Install-OctoInfrastructure.psm1
git -C octo-tools commit -m "Extend Install-OctoKubernetes to provision in-cluster infra with coexistence guard"
```

---

## Task 6: `Import-OctoImageToKind` helper

Used by the operator deploy (Task 7) and reusable for locally-built adapter/app images.

**Files:**
- Create: `octo-tools/modules/Import-OctoImageToKind.psm1`

- [ ] **Step 1: Write the module**

`octo-tools/modules/Import-OctoImageToKind.psm1`:
```powershell
function Import-OctoImageToKind {
    <#
.SYNOPSIS
Loads a locally-present Docker image into a kind cluster's node so pods can use
it with imagePullPolicy: IfNotPresent (no registry required).

.PARAMETER Image
Full image reference, e.g. "meshmakers/octo-communication-operator:dev".

.PARAMETER ClusterName
kind cluster name. Defaults to "kind".
#>
    param(
        [Parameter(Mandatory)] [string]$Image,
        [Parameter()] [string]$ClusterName = "kind"
    )
    if (-not (docker image inspect $Image 2>$null)) {
        Write-Error "Image '$Image' not found in the local Docker daemon. Build or pull it first."
        return
    }
    Write-Host "Loading $Image into kind cluster '$ClusterName'" -ForegroundColor Green
    & kind load docker-image $Image --name $ClusterName
    if ($LASTEXITCODE -ne 0) { Write-Error "kind load docker-image failed with exit code $LASTEXITCODE"; return }
    Write-Host "Loaded $Image" -ForegroundColor Cyan
}

Export-ModuleMember -Function @('Import-OctoImageToKind')
```

- [ ] **Step 2: Verify against a known small image**

Run (separate invocations):
```bash
docker pull busybox:1.36
pwsh -NoProfile -c '. ./octo-tools/modules/profile.ps1; Import-OctoImageToKind -Image busybox:1.36'
docker exec kind-control-plane crictl images | grep busybox
```
Expected: `kind load` reports success; `crictl images` lists `busybox`.

- [ ] **Step 3: Commit**

```bash
git -C octo-tools add modules/Import-OctoImageToKind.psm1
git -C octo-tools commit -m "Add Import-OctoImageToKind helper"
```

---

## Task 7: `operator-dev-values.yaml` + `Deploy-OctoOperator`

> **Open risk (decide at execution):** the operator container image. Default below **pulls the published image** `meshmakers/octo-communication-operator` (public on Docker Hub) at a tag you pass via `-ImageTag`. If you are modifying operator code, pass `-BuildLocal` to build from `octo-communication-operator/src/CommunicationOperator/Dockerfile` and `kind load` it — note that local build needs the monorepo NuGet feed (DebugL) and may require additional Docker build-args; validate before relying on it. A published image whose SignalR `/operatorHub` contract differs from the locally-built controller can fail to register pools — keep operator and controller versions aligned.

**Files:**
- Create: `octo-tools/kubernetes/operator-dev-values.yaml`
- Create: `octo-tools/modules/Deploy-OctoOperator.psm1`

- [ ] **Step 1: Write the operator dev values**

`octo-tools/kubernetes/operator-dev-values.yaml`:
```yaml
# Local dev values for octo-mesh-communication-operator (central mode).
# CRDs are installed separately by Install-OctoKubernetes.
octo-mesh-crds:
  enabled: false

image:
  repository: meshmakers/octo-communication-operator
  pullPolicy: IfNotPresent
  privateRegistry: ""
  tag: ""            # set via --set image.tag=...

operator:
  autoManagePools: true
  poolNamespace: octo
  defaultPoolName: default
  adapterIgnoreCertificateValidation: true
  communicationControllerUri: ""   # set via --set to https://<host-LAN-IP>:5015
  clusterDependencies:
    mongodbHost: "mongodb-0.mongodb.octo-infra.svc.cluster.local:27017"
    mongodbReplicaSet: "rs"
    rabbitMqHost: "rabbitmq.octo-infra.svc.cluster.local"
    rabbitMqUser: "guest"
    streamDataHost: "cratedb.octo-infra.svc.cluster.local"
    streamDataUser: "octo-system"
  clusterSecrets:
    mongodbUserPassword: "OctoUser1"
    mongodbAdminPassword: "OctoAdmin1"
    streamDataPassword: ""

broker:
  host: "rabbitmq.octo-infra.svc.cluster.local"
  virtualHost: "/"
  port: 5672
  username: "guest"
  password: "guest"
```

- [ ] **Step 2: Write the `Deploy-OctoOperator` module**

`octo-tools/modules/Deploy-OctoOperator.psm1`:
```powershell
function Get-HostLanIPv4 {
    # First non-loopback IPv4, mirroring the operator's DEBUG dev-webhook host pick.
    $addrs = [System.Net.Dns]::GetHostAddresses([System.Net.Dns]::GetHostName())
    foreach ($a in $addrs) {
        if ($a.AddressFamily -eq 'InterNetwork' -and -not [System.Net.IPAddress]::IsLoopback($a)) {
            return $a.IPAddressToString
        }
    }
    return $null
}

function Deploy-OctoOperator {
    <#
.SYNOPSIS
Installs the OctoMesh Communication Operator (central mode) into the local kind
cluster, wired to the host-process Communication Controller and in-cluster infra.

.PARAMETER ImageTag
Tag of the published meshmakers/octo-communication-operator image to deploy.

.PARAMETER ControllerHost
Host address adapter/operator pods use to reach the host controller. Defaults to
the first non-loopback IPv4 of this machine.

.PARAMETER BuildLocal
Build the operator image locally from its Dockerfile and kind-load it instead of
pulling the published image.
#>
    param(
        [Parameter()] [string]$branch = "",
        [Parameter()] [string]$ClusterName = "kind",
        [Parameter()] [string]$Namespace = "octo-operator-system",
        [Parameter()] [string]$ReleaseName = "octo-operator",
        [Parameter()] [string]$ImageTag = "latest",
        [Parameter()] [string]$ControllerHost = "",
        [Parameter()] [switch]$BuildLocal
    )

    $branchRootPath = [System.IO.Path]::Combine($rootPath, $branch)
    $ctx = "kind-$ClusterName"
    $chart = Join-Path $branchRootPath "octo-helm-core/src/octo-mesh-communication-operator"
    $values = Join-Path $branchRootPath "octo-tools/kubernetes/operator-dev-values.yaml"
    foreach ($p in @($chart, $values)) {
        if (!(Test-Path $p)) { Write-Error "Required path not found: $p"; return }
    }

    if ([string]::IsNullOrWhiteSpace($ControllerHost)) {
        $ControllerHost = Get-HostLanIPv4
        if (-not $ControllerHost) { Write-Error "Could not auto-detect a host LAN IPv4. Pass -ControllerHost."; return }
    }
    Write-Host "Operator will reach the controller at https://${ControllerHost}:5015" -ForegroundColor Cyan

    $image = "meshmakers/octo-communication-operator:$ImageTag"
    if ($BuildLocal) {
        $opRepo = Join-Path $branchRootPath "octo-communication-operator"
        $image = "meshmakers/octo-communication-operator:dev"
        Write-Host "Building operator image locally ($image)" -ForegroundColor Green
        & docker build -t $image -f (Join-Path $opRepo "src/CommunicationOperator/Dockerfile") $opRepo
        if ($LASTEXITCODE -ne 0) { Write-Error "docker build failed"; return }
        Import-OctoImageToKind -Image $image -ClusterName $ClusterName
        $ImageTag = "dev"
    }

    # Generate webhook CA + service certs into a temp dir (SAN must match the
    # operator Service name, which is fullnameOverride 'communication-operator').
    $certDir = Join-Path ([System.IO.Path]::GetTempPath()) "octo-op-certs"
    New-Item -ItemType Directory -Force -Path $certDir | Out-Null
    Write-Host "Generating operator webhook certificates" -ForegroundColor Green
    & "$octoCliPath/octo-cli" -c GenerateOperatorCertificates -o $certDir -n $Namespace -s "communication-operator"
    if ($LASTEXITCODE -ne 0) { Write-Error "GenerateOperatorCertificates failed"; return }

    Write-Host "Installing operator release '$ReleaseName'" -ForegroundColor Green
    & helm upgrade --install $ReleaseName $chart `
        --kube-context $ctx `
        --namespace $Namespace `
        --create-namespace `
        --values $values `
        --set "octo-mesh-crds.enabled=false" `
        --set "image.tag=$ImageTag" `
        --set "operator.communicationControllerUri=https://${ControllerHost}:5015" `
        --set-file "serviceHooks.caKey=$certDir/ca-key.pem" `
        --set-file "serviceHooks.caCrt=$certDir/ca.pem" `
        --set-file "serviceHooks.svcKey=$certDir/svc-key.pem" `
        --set-file "serviceHooks.svcCrt=$certDir/svc.pem"
    if ($LASTEXITCODE -ne 0) { Write-Error "helm upgrade --install operator failed"; return }

    & kubectl --context $ctx -n $Namespace rollout status deploy/communication-operator --timeout=180s
    Write-Host "Operator deployed." -ForegroundColor Green
}

Export-ModuleMember -Function @('Deploy-OctoOperator', 'Get-HostLanIPv4')
```

- [ ] **Step 3: Confirm the webhook Service name matches the cert SAN**

Run: `helm template octo-operator octo-helm-core/src/octo-mesh-communication-operator --set octo-mesh-crds.enabled=false | grep -E "kind: Service|name:" | grep -A1 "kind: Service"`
Expected: a Service named `communication-operator` (matching `-s communication-operator` used for the cert). If it differs, update the `-s` value and the `--set-file` SAN accordingly before proceeding.

- [ ] **Step 4: Deploy and verify (requires the host controller running for full registration)**

Run (separate invocations):
```bash
pwsh -NoProfile -c '. ./octo-tools/modules/profile.ps1; Deploy-OctoOperator -ImageTag latest'
kubectl --context kind-kind -n octo-operator-system get pods
kubectl --context kind-kind get validatingwebhookconfiguration,mutatingwebhookconfiguration | grep -i communication
```
Expected: operator pod `Running`/`Ready`; the validating/mutating webhook configurations exist. (Full pool-registration verification happens in Task 10 with the controller up.)

- [ ] **Step 5: Commit**

```bash
git -C octo-tools add kubernetes/operator-dev-values.yaml modules/Deploy-OctoOperator.psm1
git -C octo-tools commit -m "Add operator dev values + Deploy-OctoOperator cmdlet"
```

---

## Task 8: `Get-OctoKubernetesStatus` + `Uninstall-OctoKubernetes`

**Files:**
- Create: `octo-tools/modules/Get-OctoKubernetesStatus.psm1`
- Create: `octo-tools/modules/Uninstall-OctoKubernetes.psm1`

- [ ] **Step 1: Write the status module**

`octo-tools/modules/Get-OctoKubernetesStatus.psm1`:
```powershell
function Test-HostPortOpen([string]$hostName, [int]$port) {
    try {
        $client = New-Object System.Net.Sockets.TcpClient
        $iar = $client.BeginConnect($hostName, $port, $null, $null)
        $ok = $iar.AsyncWaitHandle.WaitOne(800)
        $client.Close()
        return $ok
    } catch { return $false }
}

function Get-OctoKubernetesStatus {
    param(
        [Parameter()] [string]$ClusterName = "kind"
    )
    $ctx = "kind-$ClusterName"

    if (-not ((& kind get clusters 2>$null) -split "`n" | Where-Object { $_ -eq $ClusterName })) {
        Write-Host "kind cluster '$ClusterName' does not exist." -ForegroundColor Yellow
        return
    }

    Write-Host "== Pods ==" -ForegroundColor Cyan
    & kubectl --context $ctx get pods -n octo-infra -n octo-operator-system -n octo 2>$null
    foreach ($ns in @("octo-infra", "octo-operator-system", "octo")) {
        Write-Host "-- $ns --" -ForegroundColor DarkCyan
        & kubectl --context $ctx -n $ns get pods
    }

    Write-Host "== Helm releases ==" -ForegroundColor Cyan
    & helm --kube-context $ctx list -A

    Write-Host "== Host port reachability ==" -ForegroundColor Cyan
    foreach ($p in @(@{n="mongodb";port=27017}, @{n="rabbitmq-amqp";port=5672}, @{n="rabbitmq-mgmt";port=15672}, @{n="cratedb-psql";port=5432}, @{n="cratedb-http";port=4301})) {
        $state = if (Test-HostPortOpen "localhost" $p.port) { "OPEN" } else { "closed" }
        Write-Host ("  {0,-16} localhost:{1,-6} {2}" -f $p.n, $p.port, $state)
    }
}

Export-ModuleMember -Function @('Get-OctoKubernetesStatus')
```

- [ ] **Step 2: Write the uninstall module**

`octo-tools/modules/Uninstall-OctoKubernetes.psm1`:
```powershell
function Uninstall-OctoKubernetes {
    param(
        [Parameter()] [string]$ClusterName = "kind",
        [Parameter()] [switch]$Force
    )
    if (-not ((& kind get clusters 2>$null) -split "`n" | Where-Object { $_ -eq $ClusterName })) {
        Write-Host "kind cluster '$ClusterName' does not exist." -ForegroundColor Yellow
        return
    }
    if (-not $Force) {
        Write-Warning "This deletes the kind cluster '$ClusterName' and ALL its data (Mongo + CrateDB PVCs are destroyed)."
        $ans = Read-Host "Type 'yes' to continue"
        if ($ans -ne "yes") { Write-Host "Aborted." -ForegroundColor Yellow; return }
    }
    & kind delete cluster --name $ClusterName
    if ($LASTEXITCODE -ne 0) { Write-Error "kind delete cluster failed with exit code $LASTEXITCODE"; return }
    Write-Host "Cluster '$ClusterName' deleted." -ForegroundColor Green
}

Export-ModuleMember -Function @('Uninstall-OctoKubernetes')
```

- [ ] **Step 3: Verify both**

Run (separate invocations):
```bash
pwsh -NoProfile -c '. ./octo-tools/modules/profile.ps1; Get-OctoKubernetesStatus'
pwsh -NoProfile -c '. ./octo-tools/modules/profile.ps1; Uninstall-OctoKubernetes -Force'
```
Expected: status prints pod tables + `OPEN` for the mapped ports while the cluster is up; uninstall deletes the cluster.

- [ ] **Step 4: Commit**

```bash
git -C octo-tools add modules/Get-OctoKubernetesStatus.psm1 modules/Uninstall-OctoKubernetes.psm1
git -C octo-tools commit -m "Add Get-OctoKubernetesStatus + Uninstall-OctoKubernetes cmdlets"
```

---

## Task 9: Register new modules in `profile.ps1`

**Files:**
- Modify: `octo-tools/modules/profile.ps1`

- [ ] **Step 1: Add the `$kubernetesPath` global**

After line 29 (`$infrastructurePath = Resolve-Path ...`) add:
```powershell
$kubernetesPath = Resolve-Path (Join-Path $toolsPath "kubernetes/")
```

- [ ] **Step 2: Import the new modules**

After the existing `Import-Module "$modulePath/Remove-KubeConfig.psm1"` line, add:
```powershell
Import-Module "$modulePath/Import-OctoImageToKind.psm1"
Import-Module "$modulePath/Deploy-OctoOperator.psm1"
Import-Module "$modulePath/Get-OctoKubernetesStatus.psm1"
Import-Module "$modulePath/Uninstall-OctoKubernetes.psm1"
```

- [ ] **Step 3: Verify all cmdlets load via the profile**

Run: `pwsh -NoProfile -c '. ./octo-tools/modules/profile.ps1; Get-Command Install-OctoKubernetes, Deploy-OctoOperator, Get-OctoKubernetesStatus, Uninstall-OctoKubernetes, Import-OctoImageToKind | Select-Object Name'`
Expected: all five names listed, no "not recognized" errors.

- [ ] **Step 4: Commit**

```bash
git -C octo-tools add modules/profile.ps1
git -C octo-tools commit -m "Register local-k8s cmdlets + kubernetesPath in profile"
```

---

## Task 10: End-to-end smoke validation + runbook

Validate the §12 acceptance flow and capture it as a runbook.

**Files:**
- Create: `octo-tools/kubernetes/README.md`

- [ ] **Step 1: Run the full stack end to end**

Run (separate invocations; ensure docker-compose infra is stopped first):
```bash
pwsh -NoProfile -c '. ./octo-tools/modules/profile.ps1; Install-OctoKubernetes'
pwsh -NoProfile -c '. ./octo-tools/modules/profile.ps1; Invoke-BuildAll -configuration DebugL -excludeFrontend $true'
pwsh -NoProfile -c '. ./octo-tools/modules/profile.ps1; Start-Octo -nonInteractive $true -configuration DebugL'
pwsh -NoProfile -c '. ./octo-tools/modules/profile.ps1; Invoke-OctoCliLoginLocal'
pwsh -NoProfile -c '. ./octo-tools/modules/profile.ps1; Deploy-OctoOperator -ImageTag latest'
```
Expected: infra Ready; host services start and `octo-cli -c AuthStatus` succeeds (proves Mongo/RabbitMQ reachable from host); operator pod Ready.

- [ ] **Step 2: Deploy a tenant adapter through the operator and confirm**

Using `octo-cli`/Studio, create tenant `e2etest`, create a **Cloud** pool, deploy it, then deploy a mesh-adapter workload (see `octo/` skill workflows). Verify:
```bash
kubectl --context kind-kind -n octo get communicationpool
kubectl --context kind-kind -n octo get pods
helm --kube-context kind-kind list -n octo
```
Expected: a `CommunicationPool` CR exists; an adapter pod is `Running` in `ns: octo`; `helm list` shows a `{tenantId}-{workload}` release.

- [ ] **Step 3: Deploy the demo-app (arbitrary application) and confirm**

```bash
helm --kube-context kind-kind upgrade --install demoapp octo-helm-core/src/octo-mesh-demo-app -n octo --values octo-helm-core/src/examples/demo-app-sample.yaml
kubectl --context kind-kind -n octo get pods -l app.kubernetes.io/instance=demoapp
kubectl --context kind-kind -n octo port-forward deploy/demoapp 8080:80
```
Expected: demo-app pod `Running`; `curl localhost:8080` returns a response.

- [ ] **Step 4: Write the runbook capturing the verified commands**

`octo-tools/kubernetes/README.md` — document: prerequisites (kind/helm/kubectl/docker on PATH; docker-compose infra stopped); one-time bring-up (`Install-OctoKubernetes` → `Deploy-OctoOperator`); daily use (`Start-Octo` host services against kind infra); status (`Get-OctoKubernetesStatus`); teardown (`Uninstall-OctoKubernetes`); the in-cluster DNS + host-port table; and troubleshooting (stale `dev-mutators`/`dev-validators`, wrong `-ControllerHost` on VPN, `kind load` for local images). Use the exact commands verified in Steps 1-3.

- [ ] **Step 5: Commit**

```bash
git -C octo-tools add kubernetes/README.md
git -C octo-tools commit -m "Add local k8s dev env runbook + validate end-to-end smoke flow"
```

---

## Self-Review

**1. Spec coverage** (each spec section → task):
- §2 in-scope infra in-cluster → Tasks 2,3,4,5. CRDs/operator → existing `Install-OctoKubernetes` + Task 7. Adapter/app deploy → Task 10. ✓
- §4/§6 host↔cluster wiring (NodePort + extraPortMappings; host LAN IP) → Task 1 (mappings), Tasks 2-4 (NodePorts), Task 7 (controller URI). ✓
- §5.2 Mongo keyFile + RS init mitigations → Task 4 (init-container + exec init). ✓
- §5.3 operator central mode + webhook certs (no cert-manager) → Task 7. ✓
- §7 cmdlet surface → Tasks 5,6,7,8,9. Coexistence guard → Task 5. ✓
- §8 repo layout → matches File Structure. ✓
- §9 secrets/certs → Task 5 (keyFile/creds), Task 7 (webhook certs); identity signing key correctly not needed (identity host-process). ✓
- §10 backups deferred → noted in Task 8 uninstall warning + runbook (Task 10). ✓
- §11 failure modes → mitigations embedded (keyFile init-container T4; coexistence guard T5; host-IP override T7; `discovery.type=single-node` T3). ✓
- §12 acceptance → Task 10. ✓

**2. Placeholder scan:** No "TBD/TODO". The one genuine unknown (operator image build vs pull) is called out explicitly with a concrete default (pull `:latest`) and a `-BuildLocal` fallback + a validation step — not a placeholder.

**3. Type/name consistency:** Service/namespace/DNS names consistent across tasks (`mongodb`/`mongodb-ext`, `rabbitmq`, `cratedb`/`cratedb-ext`, `octo-infra`/`octo`/`octo-operator-system`); NodePorts (30017/30672/31672/30543/30420) match `extraPortMappings` host ports (27017/5672/15672/5432/4301); operator Service `communication-operator` matches the cert `-s` arg (with a Task 7 step to confirm). Cmdlet names match `profile.ps1` registrations (Task 9).

**Known to verify during execution** (flagged, not blocking): exact published operator image tag; whether the host services use Crate PG (5432) vs HTTP — both host ports are exposed so either works; the operator webhook Service name (Task 7 Step 3 confirms before cert use).
