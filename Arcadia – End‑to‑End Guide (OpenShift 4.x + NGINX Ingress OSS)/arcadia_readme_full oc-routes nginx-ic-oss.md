# Arcadia – End‑to‑End Guide (OpenShift 4.x + NGINX Ingress OSS)

> **Purpose:** A *fully reproducible*, deeply explained walkthrough to deploy the sample **Arcadia** micro‑application (four services: `main`, `backend`, `app2`, `app3`) on an **OpenShift 4.x** cluster and expose it via the **NGINX Ingress Controller (open source)** fronted by an OpenShift *Route*. The document is intentionally verbose and pedagogical: **every step answers “WHAT are we doing?” and “WHY are we doing it?”** so that a newcomer can follow, while remaining technically precise for advanced users.
>
> We keep the original upstream container images which listen on privileged TCP port **80** to show real‑world constraints (privileged port binding, Security Context Constraints, etc.). We show how to make them run quickly (granting the `anyuid` SCC) and outline the production‑grade alternative (rebuild for non‑root / high ports, capabilities, or setcap). TLS variants, troubleshooting matrix, hardening roadmap, and cleanup are included.

---
## TABLE OF CONTENTS
1. [High‑Level Architecture & Request Flow](#1-high-level-architecture--request-flow)
2. [Exposure Strategies Overview](#2-exposure-strategies-overview)
3. [Prerequisites (Workstation & Cluster)](#3-prerequisites-workstation--cluster)
4. [Workstation Tooling Installation (Detailed WHY)](#4-workstation-tooling-installation-detailed-why)
5. [Logging in to OpenShift](#5-logging-in-to-openshift)
6. [Repository & File Layout](#6-repository--file-layout)
7. [Step A – Create Namespace & ServiceAccount](#7-step-a--create-namespace--serviceaccount)
8. [Step B – Deploy Raw Arcadia Manifests](#8-step-b--deploy-raw-arcadia-manifests)
9. [Step C – Why Pods Crash (Privileged Port Binding) & Solution Options](#9-step-c--why-pods-crash-privileged-port-binding--solution-options)
10. [Step D – Apply `anyuid` SCC (Quick Lab Fix)](#10-step-d--apply-anyuid-scc-quick-lab-fix)
11. [Step E – Install NGINX Ingress Controller (Working Variant)](#11-step-e--install-nginx-ingress-controller-working-variant)
12. [Step F – Expose the Controller via OpenShift Route](#12-step-f--expose-the-controller-via-openshift-route)
13. [Step G – Create Application Ingress (Path‑Based Routing)](#13-step-g--create-application-ingress-path-based-routing)
14. [End‑to‑End Functional Test](#14-end-to-end-functional-test)
15. [TLS Variants (Edge vs Ingress Termination)](#15-tls-variants-edge-vs-ingress-termination)
16. [Ingress vs OpenShift Routes – Functional Differences](#16-ingress-vs-openshift-routes--functional-differences)
17. [Troubleshooting Matrix & Commands](#17-troubleshooting-matrix--commands)
18. [Hardening & Production Considerations](#18-hardening--production-considerations)
19. [Roadmap – Next Expansion Steps](#19-roadmap--next-expansion-steps)
20. [Full Cleanup](#20-full-cleanup)
21. [Appendices – Complete YAML & Scripts](#21-appendices--complete-yaml--scripts)

---
## 1. High‑Level Architecture & Request Flow
```
Browser → DNS (arcadia.apps.netoro.lab) → OpenShift Router (Route object) → Service (NGINX Ingress Controller) → NGINX evaluates Ingress rules
  → (Path match) → ClusterIP Service (main / backend / app2 / app3) → Pod
```
**Why this layering?**
* OpenShift’s built‑in Router (HAProxy) understands **Route** objects, not Kubernetes **Ingress** objects.
* The **NGINX Ingress Controller** translates *Ingress* objects into NGINX configuration (enabling path‑based multiplexing across multiple Services under a single host – something plain Routes cannot do elegantly without multiple hostnames).
* We keep a single external FQDN (`arcadia.apps.netoro.lab`) and perform internal L7 routing by URL path.

---
## 2. Exposure Strategies Overview
| Strategy | Description | Advantages | Trade‑Offs | Selected Here |
|----------|-------------|------------|-----------|---------------|
| Multiple OpenShift Routes (one per Service / host) | Each microservice published under its own host | Simple, native | Fragmented FQDNs, no consolidated path routing | Reference only |
| **Route → NGINX Ingress Controller → Ingress rules** | Single external host; NGINX does path routing | Consolidated UX; advanced annotations; future WAF integration | Additional controller to operate | **Yes** |
| LoadBalancer Service (cloud) + Ingress | Direct LB → controller (no HAProxy layer) | Fewer hops in cloud | On‑prem LB often unavailable; loses Router features | Optional alt |

---
## 3. Prerequisites (Workstation & Cluster)
### Workstation (Ubuntu)
* Outbound Internet (pull public images & Helm chart).
* Installed: `curl`, `git`, `helm`, `oc` (OpenShift CLI).
* Text editor (vim/nano/VSCode) for manifests.

### Cluster
* OpenShift 4.x (admin or project admin rights).
* Cluster can pull from: `registry.gitlab.com` (Arcadia images) and `registry.k8s.io` (NGINX controller image).
* Know (or can discover) the Router’s external IP / routable VIP (used in `/etc/hosts` during lab if no wildcard DNS).

### DNS / Host Entry (Lab Simplification)
Add to your workstation `/etc/hosts` (or Windows `C:\Windows\System32\drivers\etc\hosts`):
```
10.1.10.140 arcadia.apps.netoro.lab
```
Adjust `10.1.10.140` to your cluster’s router canonical IP. This bypasses the need for wildcard DNS while learning.

### Design Intent
* Keep *original* images (listen on privileged port 80) to illustrate security context constraints.
* Show the minimal intrusive fix (grant `anyuid` SCC) and contrast with production best practices (rebuild to non‑root high port).

---
## 4. Workstation Tooling Installation (Detailed WHY)
### 4.1 Base Packages
```bash
sudo apt update
sudo apt install -y curl wget git ca-certificates gnupg lsb-release
```
**Why:** Foundation utilities (download scripts, verify signatures, clone repository). `ca-certificates` ensures TLS validation; `gnupg` for key imports (e.g., Helm repo GPG); `lsb-release` for packaging metadata.

### 4.2 Helm (Official Script – Fastest Path)
```bash
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
helm version
```
**Why:** Helm streamlines installation/upgrade/rollback of the Ingress controller. Single command codifies ~dozens of YAML resources.

*Alternative (APT repo) or offline binary approach can be added if supply chain policies disallow pipeline script execution.*

### 4.3 OpenShift CLI (`oc`)
If you already have it skip; otherwise from Red Hat mirror (example):
```bash
# Example (adjust version):
wget https://mirror.openshift.com/pub/openshift-v4/clients/ocp/latest/openshift-client-linux.tar.gz
sudo tar -xzf openshift-client-linux.tar.gz -C /usr/local/bin oc kubectl
oc version --client
```
**Why:** `oc` supplies OpenShift‑specific extensions (SCC operations, Route management) beyond generic `kubectl`.

---
## 5. Logging in to OpenShift
```bash
oc login https://api.oc-cluster-01.netoro.lab:6443 \
  --username=<USER> --password=<PASSWORD>
# OR token-based
oc login --token=<TOKEN> --server=https://api.oc-cluster-01.netoro.lab:6443

oc whoami
oc get nodes
```
**Why:** Confirms authentication & API reachability; verifying nodes ensures RBAC allows cluster reading.

---
## 6. Repository & File Layout
```
manifests/
  00-namespace-arcadia.yaml        # Namespace isolation
  01-all-apps.yaml                 # Original multi-service Arcadia spec (Services + Deployments)
  02-serviceaccount-anyuid.yaml    # ServiceAccount used to attach SCC anyuid (lab convenience)
  03-patch-anyuid.sh               # Script to patch each Deployment to use SA
  10-ingress-nginx-values.yaml     # Helm values tailoring controller to OpenShift
  11-ingress-arcadia.yaml          # Ingress rules (path-based fanout)
  12-route-controller.yaml         # (Optional) Declarative Route exposing controller
```
**Why structured?** Predictable, Git-friendly layering enables incremental adoption of GitOps or pipeline automation (e.g., Argo CD syncing `manifests/`).

---
## 7. Step A – Create Namespace & ServiceAccount
```bash
oc apply -f manifests/00-namespace-arcadia.yaml
oc apply -f manifests/02-serviceaccount-anyuid.yaml
oc project arcadia
```
**Why:** A dedicated namespace offers logical scoping (resource quotas, RBAC boundaries, labels/policies). The `ServiceAccount` is a *handle* we will later elevate (grant `anyuid`) without altering upstream Deployment YAML.

---
## 8. Step B – Deploy Raw Arcadia Manifests
```bash
oc apply -f manifests/01-all-apps.yaml -n arcadia
oc get pods -n arcadia -w
```
**What happens:** The four Deployments schedule Pods; each container tries to bind to port 80 inside its filesystem context.
**Why they likely fail (CrashLoopBackOff):** Under OpenShift’s default *restricted* SCC, the process runs as a non‑root random UID (e.g. 10008xxxx) without `CAP_NET_BIND_SERVICE`. Binding to a port <1024 fails (`EACCES`). The container exits, kubelet restarts it → CrashLoop.

---
## 9. Step C – Why Pods Crash (Privileged Port Binding) & Solution Options
**Root Cause:** Privileged ports (<1024) require either root or a process with the `CAP_NET_BIND_SERVICE` capability. The images were built assuming root (common in legacy or PoC images).

**Option Matrix:**
| Approach | Effort | Security Posture | Image Change Needed | Notes |
|----------|--------|------------------|---------------------|-------|
| Grant `anyuid` SCC | Very Low | Weaker (broad privilege) | No | *Fast lab unblock* |
| Rebuild images to listen on 8080 + non-root USER | Medium | Strong | Yes | **Production recommended** |
| Add capability via `setcap` (initContainer) | Medium | Moderate | No (but modify deployment) | Requires writable FS or copy-on-write layer |
| Use Pod Security Admission (K8s) custom exceptions | Medium | Strong | No | OCP still relies on SCC concurrently |

**We pick** `anyuid` for *speed of demonstration*, documenting why it is not ideal for production.

---
## 10. Step D – Apply `anyuid` SCC (Quick Lab Fix)
```bash
oc adm policy add-scc-to-user anyuid -z arcadia-anyuid -n arcadia
bash manifests/03-patch-anyuid.sh
# Force re-creation so new SCC annotation applies
oc delete pod -l app -n arcadia
oc get pods -n arcadia -w
```
**Verification:**
```bash
POD=$(oc get pod -n arcadia -l app=main -o jsonpath='{.items[0].metadata.name}')
oc get pod $POD -n arcadia -o jsonpath='{.metadata.annotations.openshift\.io/scc}{"\n"}'
oc exec -n arcadia $POD -- id
```
Expect SCC=anyuid and `uid=0(root)`.
**Why delete pods?** SCC assignment occurs at Pod admission time; existing Pods retain the previous SCC context.

> **Security Note:** `anyuid` allows containers to run as root or any specified UID. Minimize its scope (namespace-limited ServiceAccount) and prefer image refactor later.

---
## 11. Step E – Install NGINX Ingress Controller (Working Variant)
We use Helm chart `ingress-nginx` with a tailored values file to avoid admission webhook Jobs (which can fail under restrictive SCC) and allow OpenShift to inject a dynamic UID (we explicitly null `runAsUser` / `runAsGroup`).

**Values file:** `manifests/10-ingress-nginx-values.yaml` (see Appendix for full content)

**Install:**
```bash
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update
helm upgrade --install arcadia-ing ingress-nginx/ingress-nginx \
  --version 4.13.0 \
  -n ingress-nginx --create-namespace \
  -f manifests/10-ingress-nginx-values.yaml \
  --timeout 5m --debug
```
**Why these flags:**
* `--install` handles first deploy and subsequent upgrades idempotently.
* `--timeout 5m` prevents indefinite hang if an image pull or webhook stalls.
* Disabling admission webhooks removes extra Jobs that would require additional SCC tuning.

**Check:**
```bash
oc get pods -n ingress-nginx
```
Pod should be `1/1 Running`.

---
## 12. Step F – Expose the Controller via OpenShift Route
The controller Service is `ClusterIP` (internal only). The Router (HAProxy) needs a *Route* to forward external traffic into that Service.
```bash
oc expose service arcadia-ing-ingress-nginx-controller \
  -n ingress-nginx \
  --name=nginx-ingress \
  --hostname=arcadia.apps.netoro.lab
```
**Why not LoadBalancer or NodePort?** On many on‑prem OpenShift installs no cloud LB is present; NodePorts add manual IP:port management. Route leverages the platform-native entry layer.

Test (may be 404 until Ingress rules exist):
```bash
curl -I http://arcadia.apps.netoro.lab
```

---
## 13. Step G – Create Application Ingress (Path‑Based Routing)
```bash
oc apply -f manifests/11-ingress-arcadia.yaml -n arcadia
oc describe ingress arcadia-ingress -n arcadia
```
**Why:** This is where we consolidate four backend services under one host using distinct URL prefixes (`/`, `/files`, `/api`, `/app3`). The NGINX controller dynamically renders new virtual server config when it detects this resource.

---
## 14. End‑to‑End Functional Test
Populate `/etc/hosts` if DNS not set (already shown). Then:
```bash
for p in "" files api app3; do 
  printf "Testing /%s -> " "$p"; 
  curl -s -o /dev/null -w "%{http_code}\n" http://arcadia.apps.netoro.lab/$p; 
 done
```
**Expected:** HTTP 200 (or service‑specific codes). If 404 → rule mismatch; if 503 → endpoints missing.

Inspect endpoints if issues:
```bash
oc get endpoints -n arcadia main backend app2 app3
```

---
## 15. TLS Variants (Edge vs Ingress Termination)
### 15.1 Edge TLS (Router Terminates)
**When:** Quick demonstration; leverage existing HAProxy configuration; central TLS termination.
```bash
openssl req -x509 -nodes -newkey rsa:2048 -days 365 \
  -keyout arcadia.key -out arcadia.crt \
  -subj "/CN=arcadia.apps.netoro.lab/O=Arcadia"

oc delete route nginx-ingress -n ingress-nginx --ignore-not-found
oc create route edge nginx-ingress \
  -n ingress-nginx \
  --service=arcadia-ing-ingress-nginx-controller \
  --hostname=arcadia.apps.netoro.lab \
  --cert=arcadia.crt --key=arcadia.key \
  --insecure-policy=Redirect

curl -kI https://arcadia.apps.netoro.lab/
```
**Why:** Offloads TLS from NGINX; simpler cert rotation (central place). `--insecure-policy=Redirect` forces HTTP→HTTPS upgrade.

### 15.2 TLS Termination Inside NGINX (Ingress Spec)
**When:** Need fine‑grained TLS tuning, mTLS, per‑Ingress certificates.
1. Create secret in the *application* namespace:
```bash
oc create secret tls arcadia-tls -n arcadia --cert=arcadia.crt --key=arcadia.key
```
2. Extend Ingress (snippet to add under `spec:`):
```yaml
tls:
- hosts:
  - arcadia.apps.netoro.lab
  secretName: arcadia-tls
```
3. Apply & test:
```bash
oc apply -f manifests/11-ingress-arcadia.yaml -n arcadia
curl -kI https://arcadia.apps.netoro.lab/
```
**Why difference matters:** Edge TLS keeps internal hops HTTP; Ingress‑side TLS keeps encryption to the controller and can enable mutual auth or SNI-based policies.

---
## 16. Ingress vs OpenShift Routes – Functional Differences
| Capability | Ingress (NGINX) | Route | Comment |
|------------|-----------------|-------|---------|
| Multiple path → multiple Services (one host) | ✔ | ✖ (one backend per Route) | Core reason we add NGINX |
| Fine‑grained rewrites, custom headers | ✔ (annotations / ConfigMap) | Limited | Advanced L7 logic |
| mTLS to backend | ✔ | Harder / external | Security & zero‑trust patterns |
| Native WAF modules / App Protect | ✔ (NGINX Plus / modules) | External | Future enhancement |
| Canary / traffic splitting by weight | ✔ (Ingress annotations) | Limited | Progressive delivery |
| Single external CN consolidation | ✔ | Requires wildcard + many Routes | Simplicity for users |

---
## 17. Troubleshooting Matrix & Commands
| Symptom | Primary Check | Meaning | Follow‑Up Action |
|---------|---------------|---------|------------------|
| Pod CrashLoop (Arcadia) | `oc logs pod/<pod> --previous` | Likely bind permission error | Apply `anyuid` or rebuild image on high port |
| Controller Pod Pending / CreateContainerError | `oc get pods -n ingress-nginx` | SCC / security context mis-match | Review values file / disable webhooks |
| 404 from host | Controller logs: `oc logs deploy/arcadia-ing-ingress-nginx-controller -n ingress-nginx | grep arcadia` | Ingress not loaded or host mismatch | Check `ingressClassName`, host spelling |
| 503 Service Unavailable | `oc get endpoints -n arcadia <svc>` | No healthy backend pods | Fix deployment / readiness |
| Route not admitted | `oc describe route nginx-ingress -n ingress-nginx` | Host collision / wildcard mismatch | Adjust hostname / ensure router wildcard covers domain |
| TLS handshake failure | `oc get secret arcadia-tls -n arcadia` | Bad cert/secret ref | Recreate secret / reapply Ingress |
| No path routing but host resolves | `oc describe ingress arcadia-ingress -n arcadia` | Ingress missing paths | Reapply manifest |
| Performance spikes | `oc top pods -n ingress-nginx` (if metrics) | Resource pressure | Tune HPA / resources |

Supplemental commands:
```bash
oc get ingress -A
oc get route -A
oc get events -n ingress-nginx --sort-by=.lastTimestamp | tail -n 25
oc describe ingress arcadia-ingress -n arcadia
```

---
## 18. Hardening & Production Considerations
| Domain | Action | Rationale |
|--------|--------|-----------|
| Image Hygiene | Rebuild images to run non‑root, listen on 8080 | Eliminate `anyuid` reliance |
| Principle of Least Privilege | Remove `anyuid`; rely on `restricted-v2` SCC | Reduce risk surface |
| Network Policy | Define ingress/egress NetworkPolicies | Contain lateral movement |
| TLS Lifecycle | Automate via cert‑manager (ACME / internal CA) | Short‑lived cert rotation |
| Observability | Enable controller metrics + Prometheus + dashboards | Capacity & SLA insight |
| Logging | Centralize (EFK / Loki) + trace IDs | Faster incident diagnosis |
| Rate Limiting / WAF | Introduce NGINX App Protect / F5 BIG-IP / XC WAAP | L7 threat mitigation |
| Secrets Management | External secret operator / vault integration | Avoid plaintext in Git |
| Policy Enforcement | OPA Gatekeeper / Validating Admission Policies | Enforce required labels / security contexts |
| Progressive Delivery | Add canary / blue‑green (Ingress annotation or service mesh) | Safer releases |
| Supply Chain | Sign images (cosign), verify in admission | Integrity guarantees |

---
## 19. Roadmap – Next Expansion Steps
1. **Refactor Arcadia images** (USER non-root, port 8080) + remove `anyuid`.
2. Add **metrics** (enable `controller.metrics.enabled=true`; integrate Prometheus Operator + ServiceMonitor).
3. **Tracing**: instrument services (OpenTelemetry) and propagate headers through NGINX.
4. **Canary traffic splitting** (two Deployments with weights) or adopt service mesh (Istio / Linkerd) if needed.
5. **mTLS backend**: secure internal service hops.
6. Integrate **F5 BIG-IP (CIS)** or **F5 Distributed Cloud (XC)** for global load balancing + WAAP.
7. Apply **rate limiting / bot defense** policies (NGINX modules / external WAAP).
8. GitOps pipeline (Argo CD) with environment overlays (dev / staging / prod).
9. Implement **OPA/Gatekeeper** policies: disallow privileged ports unless justified.
10. Security scanning in CI (Trivy / Grype) + fail on high severity.

---
## 20. Full Cleanup
```bash
# Ingress layer
oc delete ingress arcadia-ingress -n arcadia --ignore-not-found
oc delete route nginx-ingress -n ingress-nginx --ignore-not-found
# Controller
helm uninstall arcadia-ing -n ingress-nginx || true
oc delete namespace ingress-nginx --ignore-not-found
# Application layer
oc delete -f manifests/01-all-apps.yaml -n arcadia --ignore-not-found || true
oc delete -f manifests/02-serviceaccount-anyuid.yaml --ignore-not-found || true
oc delete namespace arcadia --ignore-not-found
# Verification
oc get ns | egrep 'arcadia|ingress-nginx' || echo 'Removed'
```

---
## 21. Appendices – Complete YAML & Scripts
### 00-namespace-arcadia.yaml
```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: arcadia
```
### 01-all-apps.yaml
```yaml
##################################################################################################
# BACKEND
##################################################################################################
apiVersion: v1
kind: Service
metadata:
  name: backend
  labels:
    app: backend
    service: backend
spec:
  type: NodePort
  ports:
  - port: 80
    nodePort: 30181
    name: backend-80
  selector:
    app: backend
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: backend
  labels:
    app: backend
    version: v1
spec:
  replicas: 1
  selector:
    matchLabels:
      app: backend
      version: v1
  template:
    metadata:
      labels:
        app: backend
        version: v1
    spec:
      containers:
      - env:
        - name: service_name
          value: backend
        image: registry.gitlab.com/arcadia-application/back-end/backend:latest
        imagePullPolicy: IfNotPresent
        name: backend
        ports:
        - containerPort: 80
          protocol: TCP
---
##################################################################################################
# MAIN
##################################################################################################
apiVersion: v1
kind: Service
metadata:
  name: main
  labels:
    app: main
    service: main
spec:
  type: NodePort
  ports:
  - name: main-80
    nodePort: 30182
    port: 80
    protocol: TCP
    targetPort: 80
  selector:
    app: main
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: main
  labels:
    app: main
    version: v1
spec:
  replicas: 1
  selector:
    matchLabels:
      app: main
      version: v1
  template:
    metadata:
      labels:
        app: main
        version: v1
    spec:
      containers:
      - env:
        - name: service_name
          value: main
        image: registry.gitlab.com/arcadia-application/main-app/mainapp:latest
        imagePullPolicy: IfNotPresent
        name: main
        ports:
        - containerPort: 80
          protocol: TCP
---
##################################################################################################
# APP2
##################################################################################################
apiVersion: v1
kind: Service
metadata:
  name: app2
  labels:
    app: app2
    service: app2
spec:
  type: NodePort
  ports:
  - port: 80
    name: app2-80
    nodePort: 30183
  selector:
    app: app2
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: app2
  labels:
    app: app2
    version: v1
spec:
  replicas: 1
  selector:
    matchLabels:
      app: app2
      version: v1
  template:
    metadata:
      labels:
        app: app2
        version: v1
    spec:
      containers:
      - env:
        - name: service_name
          value: app2
        image: registry.gitlab.com/arcadia-application/app2/app2:latest
        imagePullPolicy: IfNotPresent
        name: app2
        ports:
        - containerPort: 80
          protocol: TCP
---
##################################################################################################
# APP3
##################################################################################################
apiVersion: v1
kind: Service
metadata:
  name: app3
  labels:
    app: app3
    service: app3
spec:
  type: NodePort
  ports:
  - port: 80
    name: app3-80
    nodePort: 30184
  selector:
    app: app3
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: app3
  labels:
    app: app3
    version: v1
spec:
  replicas: 1
  selector:
    matchLabels:
      app: app3
      version: v1
  template:
    metadata:
      labels:
        app: app3
        version: v1
    spec:
      containers:
      - env:
        - name: service_name
          value: app3
        image: registry.gitlab.com/arcadia-application/app3/app3:latest
        imagePullPolicy: IfNotPresent
        name: app3
        ports:
        - containerPort: 80
          protocol: TCP
```
### 02-serviceaccount-anyuid.yaml
```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: arcadia-anyuid
  namespace: arcadia
```
### 03-patch-anyuid.sh
```bash
#!/usr/bin/env bash
set -e
for d in main backend app2 app3; do
  oc patch deployment $d -n arcadia -p '{"spec":{"template":{"spec":{"serviceAccountName":"arcadia-anyuid"}}}}'
done
```
### 10-ingress-nginx-values.yaml
```yaml
controller:
  service:
    type: ClusterIP
  ingressClass: nginx
  ingressClassResource:
    name: nginx
    enabled: true
  watchNamespace: ""
  admissionWebhooks:
    enabled: false
    patch:
      enabled: false
  containerSecurityContext:
    runAsUser: null
    runAsGroup: null
    allowPrivilegeEscalation: false
    runAsNonRoot: true
  config: {}
```
### 11-ingress-arcadia.yaml
```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: arcadia-ingress
  namespace: arcadia
spec:
  ingressClassName: nginx
  rules:
  - host: arcadia.apps.netoro.lab
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: main
            port:
              number: 80
      - path: /files
        pathType: Prefix
        backend:
          service:
            name: backend
            port:
              number: 80
      - path: /api
        pathType: Prefix
        backend:
          service:
            name: app2
            port:
              number: 80
      - path: /app3
        pathType: Prefix
        backend:
          service:
            name: app3
            port:
              number: 80
```
### 12-route-controller.yaml (Optional Declarative Form)
```yaml
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: nginx-ingress
  namespace: ingress-nginx
spec:
  host: arcadia.apps.netoro.lab
  to:
    kind: Service
    name: arcadia-ing-ingress-nginx-controller
  port:
    targetPort: http
  wildcardPolicy: None
```
---
**End of Document** – You now have a fully operational baseline ready for enhancements (TLS automation, WAF, mTLS, rate limiting, GitOps, observability).

