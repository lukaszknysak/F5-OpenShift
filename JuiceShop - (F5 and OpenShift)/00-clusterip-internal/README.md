# F5 and OWASP Juice Shop on OpenShift 4.x — **Scenario 0: ClusterIP‑only**

> **Folder:** `00-clusterip-internal/`  |  **Primary goal:** quick east‑west access & unit tests within the cluster only.
>
> This README assumes you already walked through **Episode 0** (*Prerequisites & Matrix*) and have the required tools (`oc`, Git, VS Code, etc.) on your workstation.

---

## Table of Contents

1. [Prerequisites recap](#0-prerequisites-recap)
2. [Namespace reset](#1-reset-the-namespace)
3. [ServiceAccount + anyuid SCC](#2-serviceaccount-with-anyuid)
4. [Deployment manifest](#3-deployment-manifest)
5. [ClusterIP Service](#4-clusterip-service)
6. [In‑cluster test](#5-test)
7. [Troubleshooting](#6-troubleshooting)
8. [Cleanup](#7-cleanup)
9. [Why we use ](#8-why-anyuid)[**anyuid**](#8-why-anyuid)[ here](#8-why-anyuid)

---

## 0  Prerequisites recap

- You are **logged in** to the cluster from your Ubuntu workstation: `oc login …` wrote credentials to `~/.kube/config`.
- The user has permission to **create projects** and **grant SCCs**.
- The cluster can pull public images from Docker Hub (`bkimminich/juice-shop`).

> **Note** – No wildcard DNS or router access is needed, because we stay entirely inside the cluster network.

---

## 1  Reset the namespace

```bash
# Delete any previous lab namespace (ignore errors if it never existed)
oc delete project juice-shop --wait=true || true

# Re‑create an empty namespace for this scenario
oc new-project juice-shop
```

Result: a brand‑new namespace, free of leftover Deployments or SCC labels.

---

## 2  ServiceAccount with `anyuid`

OpenShift’s *restricted‑v2* SCC blocks UID 0 **and** arbitrary fixed UIDs.  Juice Shop’s upstream image still starts as **root** and needs write access to `/.well‑known`.  Fastest fix for a lab:

```bash
# 2.1 Create a dedicated SA
oc create serviceaccount juice-anyuid -n juice-shop

# 2.2 Allow the SA to run as root
oc adm policy add-scc-to-user anyuid -z juice-anyuid -n juice-shop
```

Only this ServiceAccount can run as UID 0; the rest of the cluster stays locked down.

---

## 3  Deployment manifest

Save the YAML below as ``:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: juice-shop
  labels:
    app: juice-shop
spec:
  replicas: 1               # single‑pod demo
  selector:
    matchLabels:
      app: juice-shop
  template:
    metadata:
      labels:
        app: juice-shop
    spec:
      serviceAccountName: juice-anyuid  # created in step 2
      containers:
      - name: juice-shop
        image: bkimminich/juice-shop   # latest stable from Docker Hub
        ports:
        - containerPort: 3000          # app listener
        volumeMounts:
        - name: wellknown
          mountPath: /.well-known      # writable for metadata file
      volumes:
      - name: wellknown
        emptyDir: {}                   # tmpfs automatically root‑owned
```

Apply & watch the rollout:

```bash
oc apply -f manifests/juice-shop-deployment.yaml
oc rollout status deployment/juice-shop
```

You should see *deployment "juice-shop" successfully rolled out* within \~30 s.

*Why this passes SCC validation*

- We **do not** declare `runAsUser`, `fsGroup`, `capabilities`, or `allowPrivilegeEscalation` – the `anyuid` SCC lets the image start exactly as it was built (root).  OpenShift auto‑fills safe defaults for the rest.
- The `emptyDir` mounted on `/.well-known` is writable, so the application can create *provider‑metadata.json* without hitting `EACCES` (this is the file seen in the original crash log).


---

## 4  ClusterIP Service

Create ``:

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
    port: 80          # Service port inside the cluster
    targetPort: 3000  # containerPort defined above
```

Apply it:

```bash
oc apply -f manifests/juice-shop-service.yaml
```

> Use `oc get svc juice-shop -n juice-shop` to confirm the allocated `nodePort` if you omit the explicit value.

The application is now reachable at `http://juice-shop:80` **from any pod in the cluster**.

---

## 5  Test

Spin up a temporary curl pod and make an internal request:

```bash
oc run tmp --rm -i --tty --image=curlimages/curl --command -- sh -c \
  'curl -I http://juice-shop/ | head -n1'
```

Expected output:

```
HTTP/1.1 200 OK
```

If you get a timeout or 503, jump to the troubleshooting table below.

---

## 6  Troubleshooting

| Symptom                           | Quick command                          | Likely cause                                       |
| --------------------------------- | -------------------------------------- | -------------------------------------------------- |
| Deployment stuck in *Progressing* | `oc describe deploy/juice-shop`        | `FailedCreate`: missing **anyuid** SCC binding     |
| Pod `CrashLoopBackOff`            | `oc logs deploy/juice-shop --previous` | Cannot write to `/.well-known` (volume mount typo) |
| Curl inside cluster times out     | `oc get endpoints juice-shop`          | Pod not Ready / selector mismatch                  |

---

## 7  Cleanup

```bash
oc delete project juice-shop --wait=true
```

Good practice after every demo so the next scenario starts clean.

---

## 8  Why **anyuid**?

OpenShift assigns each namespace its own UID/GID range.  Running a container with a hard‑coded UID (including **root**) fails under the default *restricted‑v2* SCC unless you rebuild the image.  Granting **anyuid** to a single ServiceAccount is the fastest way to run unmodified upstream images in a lab.

When you later rebuild Juice Shop (or any app) to run as non‑root, you can drop this SCC entirely.

---

> **Result:** a reproducible, single‑folder lab that deploys OWASP Juice Shop inside OpenShift and makes it accessible via an internal **ClusterIP Service** – perfect for integration tests or as a building block for more advanced north‑south scenarios.

