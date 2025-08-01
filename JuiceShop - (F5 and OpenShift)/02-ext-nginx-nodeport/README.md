# F5 and OWASP Juice Shop on OpenShift 4.x — **Scenario 2 : external NGINX LB ↔ NodePort**

> **Folder:** `02-ext-nginx-nodeport/`  |  **Primary goal:** expose the NodePort service through an **on‑prem NGINX Plus instance** that runs on an Ubuntu VM outside the cluster.  Ideal when you have no OpenShift Router yet but want a quick north‑south load‑balancer.
>
> This chapter assumes you finished *Episode 0* (master README) **and** already validated Scenario 1 (*NodePort only*).  We will:
>
> 1. Build a minimal Ubuntu 22.04 LTS server (no GUI) with two NICs.
> 2. Install NGINX Plus (trial) using the official repo script.
> 3. Deploy Juice Shop on **every worker node** (scale=3) and expose it via NodePort `30001`.
> 4. Configure NGINX Plus to round‑robin across those NodePort back‑ends.

---

## Table of Contents

1. [Lab topology](#0-lab-topology)
2. [Ubuntu VM build](#1-build-the-ubuntu-host)
3. [Install NGINX Plus](#2-install-nginx-plus)
4. [OpenShift: namespace, SA, scaled deployment](#3-openshift-workload)
5. [NodePort Service](#4-nodeport-service)
6. [NGINX Plus load‑balancer config](#5-nginx-plus-configuration)
7. [End‑to‑end test](#6-test)
8. [Troubleshooting](#7-troubleshooting)
9. [Cleanup](#8-cleanup)
10. [Why an external LB?](#9-why-external)

---

## 0  Lab topology

```text
                ┌──────────────────────────────────────────────────────────┐
                │                Management / Outside LAN                 │
                │ 10.1.10.0/24                                            │
                │                                                         │
                │  ┌───────────────┐  NodePort 30001          ┌──────────┐ │
Internet → ✈ … →  │ Ubuntu 22.04  │ ───────────────────────▶ │ OCP n1   │ │
  (curl)        │  │ NGINX Plus LB │  NodePort 30001          │10.1.10.134││
                │  │10.1.1.230     │ ───────────────────────▶ │ OCP n2   │ │
                │  │10.1.10.230    │  NodePort 30001          │10.1.10.135││
                │  │10.1.20.230    │ ───────────────────────▶ │ OCP n3   │ │
                │  └───────────────┘                          │10.1.10.136││
                │                                             └──────────┘ │
                └──────────────────────────────────────────────────────────┘
```

- **Ubuntu host:** with 3 interfaces — primary NIC `ens33` → 10.1.1.230/24 (management network), secondary NIC `ens34` → 10.1.10.230/24 (GW 10.1.10.1), third `ens35` → 10.1.20.230/24 (back‑end network).
- **OpenShift workers:** 10.1.10.134–136/24.  Control‑plane & Ingress router are **not** used in this scenario.

---

## 1  Build the Ubuntu host

> *Skip if you already have a clean Ubuntu 22.04 VM.*

```bash
# 1.1 Install Ubuntu Server 22.04 (minimal) — no Desktop packages
#     Set hostname when prompted:
sudo hostnamectl set-hostname nginx-plus-lb

# 1.2 Configure primary NIC 10.1.10.230/24 with netplan
sudo tee /etc/netplan/00-installer-config.yaml >/dev/null <<'EOF'
network:
  ethernets:
    ens33:
      addresses:
      - 10.1.1.230/24
      nameservers:
        addresses:
        - 10.1.1.200
        search: []
    ens34:
      addresses:
      - 10.1.10.230/24
      nameservers:
        addresses:
        - 10.1.10.200
        search: []
      routes:
      - to: default
        via: 10.1.10.1
    ens35:
      addresses:
      - 10.1.20.230/24
      nameservers:
        addresses: []
        search: []
  version: 2
EOF

sudo netplan apply
#
# 1.3 Baseline packages & firewall
sudo apt update && sudo apt upgrade -y
sudo apt install -y curl jq ufw
sudo ufw allow ssh       # mgmt
sudo ufw allow 80/tcp    # HTTP virtual server
sudo ufw allow 443/tcp   # (TLS optional later)
sudo ufw enable
```

---

## 2  Install NGINX Plus

Upload your **customer portal credentials** files (`nginx-repo.crt`, `nginx-repo.key`) + licence (`nginx-one-eval.key`, `nginx-one-eval.jwt`) to `/tmp` on the VM (e.g. `scp`).

Run the vendor‑provided script (lightly modified to suppress prompts):

```bash
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/jay-nginx/install-nginx/master/install_nplus.sh)"
# ↳ installs nginx-plus + App Protect modules (ignored if licence missing)
```

Start & enable:

```bash
sudo systemctl enable --now nginx
sudo nginx -v   # should print something like: nginx version: nginx/1.25.x (nginx‑plus‑r30)
```

Licence activation:

```bash
sudo mkdir -p /etc/nginx/license
sudo mv /tmp/nginx-one-eval.* /etc/nginx/license/
sudo nginx -s reload
```

---

## 3  OpenShift workload (scaled NodePort)

We reuse **Scenario 1** manifests but in \*\*namespace \*\*`and` so each worker hosts one pod.

```bash
oc delete project juice-shop-nodeport --wait=true || true
oc new-project juice-shop-nodeport

# ServiceAccount + anyuid SCC
oc create serviceaccount juice-anyuid
oc adm policy add-scc-to-user anyuid -z juice-anyuid

# Deployment
cat <<'EOF' | oc apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: juice-shop
spec:
  replicas: 3            # one per worker
  selector:
    matchLabels:
      app: juice-shop
  template:
    metadata:
      labels:
        app: juice-shop
    spec:
      serviceAccountName: juice-anyuid
      containers:
      - name: juice-shop
        image: bkimminich/juice-shop
        ports:
        - containerPort: 3000
        volumeMounts:
        - name: wellknown
          mountPath: /.well-known
      volumes:
      - name: wellknown
        emptyDir: {}
EOF

# Wait until 3/3 Ready
oc rollout status deploy/juice-shop
```

---

## 4  NodePort Service

```bash
cat <<'EOF' | oc apply -f -
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
    port: 80
    targetPort: 3000
    nodePort: 30001   # chosen static port
EOF
```

Confirm:

```bash
oc get svc juice-shop -o wide
# NODE-PORT should read 30001/TCP
```

---

## 5  NGINX Plus configuration

Create `/etc/nginx/conf.d/juice-shop.conf` :

```nginx
# /etc/nginx/conf.d/juice-shop.conf
upstream juice_shop {
    zone juice_shop 64k;
    server 10.1.10.134:30001     max_fails=3 fail_timeout=15s;
    server 10.1.10.135:30001     max_fails=3 fail_timeout=15s;
    server 10.1.10.136:30001     max_fails=3 fail_timeout=15s;
}

server {
    listen 80;
    server_name juice-shop.demo.local;   # optional DNS entry / /etc/hosts

    location / {
        proxy_pass http://juice_shop;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-For $remote_addr;
    }

    health_check interval=5 fails=2 passes=1;
}
```

Reload & validate:

```bash
sudo nginx -t && sudo nginx -s reload
```

Check dashboard (Plus only):

```bash
curl -u admin:password http://localhost/api/5/http/upstreams/juice_shop | jq '.peers[] | {server, state}'
```

---

## 6  End‑to‑end test

```bash
curl -I http://10.1.10.230/
#            ▲ Ubuntu LB IP (or DNS name)
# Expect: HTTP/1.1 200 OK
```

Browse `http://10.1.10.230/` and ensure the Juice Shop UI loads.  Kill one pod (`oc delete pod …`) and watch NGINX advance to the next available back‑end.

---

## 7  Troubleshooting

| Symptom                      | Where to look / command                                 | Notes                                   |                                        |
| ---------------------------- | ------------------------------------------------------- | --------------------------------------- | -------------------------------------- |
| `curl` to LB times out       | `sudo ufw status`, \`sudo ss -lntp                      | grep :80\`                              | Port 80 blocked or NGINX not listening |
| `502 Bad Gateway` from NGINX | `/var/log/nginx/error.log`                              | NodePort unreachable / pods not Ready   |                                        |
| One peer always DOWN         | `curl http://localhost/api/5/http/upstreams/juice_shop` | Check firewall between LB & worker node |                                        |
| OpenShift pod restarts       | `oc logs -p deploy/juice-shop`                          | Volume mount / SCC issue                |                                        |

---

## 8  Cleanup

```bash
# Cluster side
oc delete project juice-shop-nodeport --wait=true

# Ubuntu LB (optional)
sudo systemctl stop nginx
sudo apt remove --purge nginx-plus* -y
```

---

## 9  Why an **external NGINX Plus** first?

- Mimics on‑prem brown‑field environments where a farm of VMs already terminates TLS.
- Zero dependence on the OpenShift Router – handy in vendor‑neutral demos.
- Introduces core L4/L7 LB concepts before adding BIG‑IP, Ingress Link or Gateway API.

> **Result:** one Ubuntu VM, one YAML apply, and you have a mini DMZ for Juice Shop — ready for further experiments like mTLS, rate‑limiting or WAF modules.

