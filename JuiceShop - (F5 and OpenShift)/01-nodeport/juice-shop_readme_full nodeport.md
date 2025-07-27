# OWASP Juice Shop on OpenShift 4.x – **from‑scratch lab guide**

> **Audience**  Anyone who wants a **repeatable, copy‑and‑paste** walkthrough that deploys OWASP Juice Shop in a *clean* OpenShift namespace and exposes it either via **Route (edge‑terminated HTTP 80)** *or* the quickest possible **NodePort**.  The guide explains *why* each step is needed so even first‑time OpenShift users understand what is going on.

---

## Deployment Option Matrix (choose your adventure)

| #  | Publishing Stack (front‑to‑back)                          | In‑cluster Controller(s) | External ADC / LB         | SSL Termination    | HTTPS Redirect | GSLB / DNS Failover   | Connectivity to OCP  | Typical Purpose                             | This README                        |
| -- | --------------------------------------------------------- | ------------------------ | ------------------------- | ------------------ | -------------- | --------------------- | -------------------- | ------------------------------------------- | ---------------------------------- |
| 1  | **ClusterIP only**                                        | —                        | —                         | None               | Manual         | —                     | — (none)             | Quick POC, used in other topologies         | **☑ current**                      |
| 2  | **NodePort only**                                         | —                        | —                         | None               | Manual         | —                     | — (direct node IP)   | Quick POC, kubectl port‑forward replacement | ☐                                  |
| 3  | **OpenShift Route (edge, HTTP 80/443)**                   | —                        | Built‑in HAProxy Router   | Router (edge)      | Yes            | Optional wildcard DNS | SDN / OVN            | Native, simplest PROD pattern               | ☐ *(separate doc)*                 |
| 4  | Route → **NGINX OSS Ingress** *(no TLS)*                  | NGINX OSS IC             | Router                    | None (HTTP)        | No             | —                     | ClusterIP Service    | Path fan‑out demo                           | ☐                                  |
| 5  | Route *(edge TLS)* → NGINX OSS IC                         | NGINX OSS IC             | Router                    | Router (edge)      | Yes (301)      | —                     | ClusterIP Service    | L7 routing, certs centralised               | ☐                                  |
| 6  | Route *(passthrough)* → NGINX OSS IC (TLS in IC)          | NGINX OSS IC             | Router                    | Ingress (PASSTHRU) | Optional       | —                     | ClusterIP Service    | mTLS, SNI policies                          | ☐                                  |
| 7  | **BIG‑IP LTM** + **CIS** (ServiceType ClusterIP)          | —                        | BIG‑IP (CIS CRDs)         | BIG‑IP             | Optional       | BIG‑IP DNS GSLB       | Static routes        | Enterprise L4/L7, central ADC               | ☐                                  |
| 8  | BIG‑IP + CIS + **NGINX OSS IC**                           | NGINX OSS IC             | BIG‑IP                    | BIG‑IP or Ingress  | Optional       | BIG‑IP DNS            | Static / BGP / VXLAN | Leverage OSS IC features with BIG‑IP front  | ☐                                  |
| 9  | BIG‑IP + CIS + **NGINX Plus IC + App Protect WAF**        | NGINX Plus IC + AP WAF   | BIG‑IP                    | BIG‑IP or Ingress  | Optional       | BIG‑IP DNS + EDNS     | Static / BGP / VXLAN | Full enterprise WAF & analytics             | ☐                                  |
| 10  | **Ingress Link** (BIG‑IP owner of routes)                | — (BIG‑IP syncs Ingress) | BIG‑IP ICR (Ingress Link) | BIG‑IP             | BIG‑IP         | Optional              | BIG‑IP DNS           | ARP / SNAT / VXLAN                          | Minimal components, central config | 
| 11 | External **NGINX (north‑south)** LB → NodePort            | — in‑cluster             | Stand‑alone NGINX         | External NGINX     | Configured     | Optional              | DNS round‑robin      | NodePort                                    | DIY LB between nodes               | 
| 12 | **Multi‑cluster GSLB** (BIG‑IP DNS Failover) + any of 6‑8 | per‑cluster IC           | BIG‑IP DNS                | At ADC tier        | Yes            | Authoritative GSLB    | Any (static/BGP)     | Active‑Passive or A/B                       | ☐                                  |

> **How to read:** *SSL Termination* = where the TLS handshake ends; *HTTPS Redirect* denotes automatic HTTP→HTTPS upgrade in that tier.  *Connectivity to OCP* lists the common mechanism BIG‑IP uses to reach Kubernetes pod networks (static routes, BGP, VXLAN encapsulation, etc.).  The **☑** marks the scenario built step‑by‑step in *this* README; unchecked rows are future guides that will live in sibling markdown files. 

> **Legend:** CIS = *Container Ingress Services* (F5); IC = *Ingress Controller*; AWAF = Advanced Web App Firewall.  A checked status means the remainder of this document walks you through that scenario.

\## Table of Contents

1. [Prerequisites](#0-prerequisites)
2. [Namespace reset](#1-full-reset-of-the-namespace)
3. [ServiceAccount + anyuid SCC](#2-create-a-dedicated-serviceaccount-that-may-run-as-root)
4. [Deployment manifest](#3-deployment-manifest)
5. [Publishing options](#4-service-and-exposure-options)
   - 5.1 Route (ClusterIP ➔ Router)
   - 5.2 NodePort (quick demo)
6. [End‑to‑end test](#5-test-end-to-end)
7. [Troubleshooting cheat‑sheet](#6-troubleshooting)
8. [Cleanup script](#7-cleanup)
9. [Why we use ](#8-why-anyuid)[**anyuid**](#8-why-anyuid)[ here](#8-why-anyuid)

---

\## 0  Prerequisites

- Logged in with `oc` (user must be able to create projects & grant SCCs).
- Cluster can pull public images from **Docker Hub**.
- Optional wildcard DNS for `*.apps.<cluster‑base>` already points at the OpenShift router (only needed for the *Route* variant).  If you do not have it, you can still reach the NodePort directly.

---

\## 1  Full reset of the namespace

```bash
# Delete the old project, wait until it disappears (ignore if it never existed)
oc delete project juice-shop --wait=true 2>/dev/null || true

# Re‑create an empty project
oc new-project juice-shop
```

> *Result:* brand‑new namespace, no ReplicaSets, no lingering SCC labels.

---

\## 2  Create a dedicated ServiceAccount that may run as root OpenShift’s *restricted‑v2* SCC blocks UID 0 and arbitrary UIDs.  Juice Shop’s upstream image still starts as **root** and needs write access to `/.well-known`.  The quickest safe path for a lab is to give exactly *one* ServiceAccount the `anyuid` SCC.

```bash
# The SA that will own the pod
oc create serviceaccount juice-anyuid -n juice-shop

# Allow this SA to use the "anyuid" SCC (root allowed, no UID range check)
oc adm policy add-scc-to-user anyuid -z juice-anyuid -n juice-shop
```

---

\## 3  Deployment manifest Save the snippet below as \`\` *beside* your README – one file, no extra scripts.

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: juice-shop
  labels:
    app: juice-shop
spec:
  replicas: 1
  selector:
    matchLabels:
      app: juice-shop
  template:
    metadata:
      labels:
        app: juice-shop
    spec:
      serviceAccountName: juice-anyuid  # from step 2
      containers:
      - name: juice-shop
        image: bkimminich/juice-shop   # upstream, latest stable
        ports:
        - containerPort: 3000          # app listens here
        volumeMounts:
        - name: wellknown
          mountPath: /.well-known      # writable dir for metadata file
      volumes:
      - name: wellknown
        emptyDir: {}                   # tmpfs; owned by root in pod
```

*Why this passes SCC validation*

- We **do not** declare `runAsUser`, `fsGroup`, `capabilities`, or `allowPrivilegeEscalation` – the `anyuid` SCC lets the image start exactly as it was built (root).  OpenShift auto‑fills safe defaults for the rest.
- The `emptyDir` mounted on `/.well-known` is writable, so the application can create *provider‑metadata.json* without hitting `EACCES` (this is the file seen in the original crash log).

Apply it & watch the rollout:

```bash
oc apply -f juice-shop-deployment.yaml -n juice-shop
oc rollout status deployment/juice-shop -n juice-shop   # completes ≤ 30 s
oc get pods -n juice-shop -w                            # expect 1/1 Running
```

---

\## 4  Service **and** exposure options ### 4.1 Create a **ClusterIP** Service (always) Save as \`\`:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: juice-shop
spec:
  selector:
    app: juice-shop
  ports:
  - name: http
    port: 80          # service port inside cluster
    targetPort: 3000  # container port
```

```bash
oc apply -f juice-shop-service.yaml -n juice-shop
```

\### 4.2 Expose option A – **Route** (OpenShift native)

```bash
oc expose service juice-shop \
  -n juice-shop \
  --hostname=juice-shop.apps.<cluster‑base>
```

- The router terminates HTTP 80 by default.
- Need HTTPS?  Add `--port=http --insecure-policy=Redirect` plus `--cert/--key` for an edge‑terminated cert.

\### 4.3 Expose option B – **NodePort** (fastest demo) If you prefer not to create a Route (e.g. no wildcard DNS), change the Service to **NodePort** instead:

```yaml
# ONLY replace the spec section shown here
spec:
  type: NodePort
  selector:
    app: juice-shop
  ports:
  - name: http
    port: 80          # inside cluster
    targetPort: 3000  # container port
    nodePort: 32080   # choose an unused port 30000‑32767
```

Apply the change:

```bash
oc apply -f juice-shop-service.yaml -n juice-shop
```

> Use `oc get svc juice-shop -n juice-shop` to confirm the allocated `nodePort` if you omit the explicit value.

---

\## 5  Test end‑to‑end ### 5.1 Using Route

```bash
curl -I http://juice-shop.apps.<cluster‑base>/
# Expect: HTTP/1.1 200 OK
```

\### 5.2 Using NodePort

```bash
NODE_IP=$(oc get nodes -o wide | awk '/worker/{print $6;exit}')
NODE_PORT=32080   # or whatever `oc get svc` says
curl -I "http://${NODE_IP}:${NODE_PORT}/"
```

Open a browser at the same URL – the Juice Shop UI should appear.

---

\## 6  Troubleshooting

| Symptom                           | Quick command                                     | Likely cause                                                    |
| --------------------------------- | ------------------------------------------------- | --------------------------------------------------------------- |
| Deployment stuck in *Progressing* | `oc describe deployment juice-shop -n juice-shop` | `FailedCreate` → SCC block.  Did you forget the anyuid binding? |
| Pod CrashLoopBackOff              | `oc logs pod/<name> -n juice-shop --previous`     | Missing `/.well-known` mount or other filesystem error          |
| Route returns **503**             | `oc get endpoints juice-shop -n juice-shop`       | Backend pod not Ready / selector typo                           |
| Browser times out (NodePort)      | `curl --resolve juice-shop.apps...`               | Wrong Node IP, firewall blocks port 32080                       |
| Port already allocated            | —                                                 | Pick another `nodePort` (range 30000‑32767)                     |

---

\## 7  Cleanup For repeated labs drop the snippet below into \`\`:

```bash
#!/usr/bin/env bash
set -e
printf '⚠  Deleting Juice Shop namespace…\n'
oc delete project juice-shop --wait=true || true
printf '✅  Done.\n'
```

Run with `bash scripts/cleanup.sh`.

---

\## 8  Why **anyuid**? OpenShift allocates each namespace its own UID/GID range.  Running *any* fixed UID (10001, 8080, …) inside the `restricted‑v2` SCC fails unless you rebuild the image or use a custom SCC.

For **quick demos**:

- keep the upstream container (root),
- attach `anyuid` to a single ServiceAccount,
- restrict network access if needed.

When you later rebuild the image to run as non‑root and listen on port 8080+, you can drop the `anyuid` SCC entirely.

---

> You now have a **repeatable, single‑file** deployment that spins up Juice Shop in a clean OpenShift namespace every time and lets you choose between Route or NodePort exposure.

