# F5 and OWASP Juice Shop on OpenShift 4.x — **Scenario 1 : NodePort‑only**

> **Folder:** `01-nodeport/`  |  **Primary goal:** lightning‑fast external PoC via the **Node’s IP + high port**.
>
> This README is a *clone* of the ClusterIP lab but tweaks the Service to `type: NodePort` and uses a **dedicated namespace** so you can run both scenarios in parallel.

---

## Table of Contents

1. [Prerequisites recap](#0-prerequisites-recap)
2. [Namespace reset](#1-reset-the-namespace)
3. [ServiceAccount + anyuid SCC](#2-serviceaccount-with-anyuid)
4. [Deployment manifest](#3-deployment-manifest)
5. [NodePort Service](#4-nodeport-service)
6. [External test](#5-test)
7. [Troubleshooting](#6-troubleshooting)
8. [Cleanup](#7-cleanup)
9. [Why we use ](#8-why-anyuid)[**anyuid**](#8-why-anyuid)

---

## 0  Prerequisites recap

- You are **logged in** from your workstation; credentials live in `~/.kube/config`.
  ```bash
  oc login -u kubeadmin -p <token> --insecure-skip-tls-verify \
    https://api.oc-cluster-01.netoro.lab:6443
  export KUBECONFIG=$HOME/oc/kubeconfig.yaml
  ```
- You can **create projects** and **grant SCCs**.
- Nodes can pull the image `bkimminich/juice-shop` from Docker Hub.
- **Firewall**: ensure TCP `30001` (or whatever `nodePort` you pick) is reachable on worker nodes from your client.

> **No DNS or router required** — the test hits a worker‑node IP directly.

---

## 1  Reset the namespace

We isolate this scenario in `` to avoid clashing with ClusterIP labs.

```bash
oc delete project juice-shop-nodeport --wait=true || true
oc new-project juice-shop-nodeport
oc project juice-shop-nodeport
```

---

## 2  ServiceAccount with `anyuid`

Same rationale as Scenario 0 – upstream image still runs as **root**.

```bash
oc create serviceaccount juice-anyuid -n juice-shop-nodeport
oc adm policy add-scc-to-user anyuid -z juice-anyuid -n juice-shop-nodeport
```

---

## 3  Deployment manifest

`manifests/juice-shop-deployment.yaml`:

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
      serviceAccountName: juice-anyuid  # SA from step 2
      containers:
      - name: juice-shop
        image: bkimminich/juice-shop   # latest stable
        ports:
        - containerPort: 3000          # app listener
        volumeMounts:
        - name: wellknown
          mountPath: /.well-known      # writable dir
      volumes:
      - name: wellknown
        emptyDir: {}
```

Apply and watch:

```bash
oc apply -f manifests/juice-shop-deployment.yaml
oc rollout status deploy/juice-shop
```

---

## 4  NodePort Service

`manifests/juice-shop-service.yaml`:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: juice-shop
spec:
  type: NodePort
  selector:
    app: juice-shop
  ports:
  - name: http
    port: 80            # Service port inside cluster
    targetPort: 3000    # containerPort
    nodePort: 30001     # choose an open port 30000‑32767
```

Apply it:

```bash
oc apply -f manifests/juice-shop-service.yaml
```

> **Tip:** omit `nodePort:` to let OpenShift pick one automatically.  Check with `oc get svc juice-shop`.

---

## 5  Test from outside the cluster

1. **Pick a worker IP** (any schedulable node that your laptop can reach):
   ```bash
   NODE_IP=$(oc get nodes -o wide | awk '/worker/{print $6;exit}')
   echo $NODE_IP
   ```
2. **Curl the NodePort**:
   ```bash
   curl -I "http://${NODE_IP}:30001/"
   # Expect: HTTP/1.1 200 OK
   ```
3. **Open a browser** at the same URL to verify the UI renders.

---

## 6  Troubleshooting

| Symptom                       | Quick command                          | Likely cause                          |
| ----------------------------- | -------------------------------------- | ------------------------------------- |
| `FailedCreate` in deployment  | `oc describe deploy/juice-shop`        | Missing **anyuid** SCC binding        |
| `CrashLoopBackOff` pod        | `oc logs deploy/juice-shop --previous` | Cannot write to `/.well-known` volume |
| Curl timeout / connection err | Check FW, verify `NODE_IP` reachable   | Port 30001 blocked or wrong worker IP |

---

## 7  Cleanup

```bash
oc delete project juice-shop-nodeport --wait=true
```

---

## 8  Why **anyuid**?

OpenShift assigns each namespace its own UID/GID range.  Containers running a fixed UID (including **root**) fail under the default *restricted‑v2* SCC unless rebuilt.  Granting **anyuid** to a single ServiceAccount is the fastest way to run untouched upstream images for demos.  Swap to a non‑root image later and you can drop this SCC entirely.

---

> **Result:** a self‑contained folder that spins up Juice Shop in its own namespace and exposes it via a **NodePort** — ideal for day‑zero external smoke‑tests without touching Routes or Ingress.

