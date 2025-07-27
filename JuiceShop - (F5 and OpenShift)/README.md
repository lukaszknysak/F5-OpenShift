# OWASP Juice Shop Labs on OpenShift 4.x — **Master README: Prerequisites & Scenario Catalog**

> _Episode 0 – read this once, then dive into any folder._  
> **Goal:** Explain **what you need** on your workstation / cluster **and where every how‑to lives**.  
> **Audience:** First‑time OpenShift users with F5 experience who want a reproducible Juice Shop deployment while learning north–south publishing patterns – from bare‑bones **ClusterIP** to **BIG‑IP + Ingress Controller + WAF**.

---

## 1. Why many scenarios?
Juice Shop is stateless, single‑container and instantly recognisable - a perfect app for testing environments like this.  Real production apps are exposed in many ways:

* **ClusterIP** for east‑west traffic inside the mesh
* **NodePort** for day‑zero “is it alive?” tests
* **Route** for edge TLS off‑load
* **NGINX Ingress** for path fan‑out
* **BIG‑IP** for enterprise ADC / WAF / GSLB

Rather than one monster guide we keep **one folder = one scenario** so you can copy‑paste safely, run two variants side‑by‑side, and read Git history without scrolling forever.

---

## 2.  Quick‑Start Checklist _(no tables – copy/paste friendly)_

### 2.1 Tools on your **Ubuntu workstation** (or macOS/WSL)
1. **Git CLI (or Github Desktop)** – local commits & branching.  `sudo apt install git`
2. **GitHub account** – remote repo for sharing/pull‑requests.  Sign up on github.com.
3. **VS Code** – YAML editing & cluster browsing.  Download, then add extensions like  _YAML_ & _Red Hat OpenShift Toolkit_.
4. **OpenShift CLI (`oc`)** – create projects, tail logs.  Download from the OpenShift Web Console → **?** → _Command‑line Tools_.  Put `oc` in `~/bin` or `/usr/local/bin`.
5. *(Optional)* **kubectl** – some IDE tasks expect it.  Ships in the same tarball as `oc`.
6. **Helm v3** – only for scenarios 4‑9 (installs NGINX Ingress).  `curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash`
7. **SSH key** – push to GitHub without passwords.  `ssh-keygen -t ed25519 -C "you@example.com"`

### 2.2 Get **kubeconfig** once
*OpenShift Web Console → **?** → Copy Login Command*  → paste the `oc login --token ...` line in your terminal. Credentials are saved to `~/.kube/config`; both `oc` and VS Code will pick them up.

### 2.3 Cluster requirements
* **OpenShift 4.10+** (tested on 4.14).  You need a user allowed to _create namespaces_ and _grant SCCs_.
* Nodes must reach **Docker Hub** (to pull `bkimminich/juice-shop`).
* For Route‑based labs: wildcard DNS `*.apps.<cluster‑base>` → router VIP (or edit `/etc/hosts`).

### 2.4 Optional BIG‑IP (rows 7‑11)
* **TMOS 17.1/17.5 VE** with LTM + DNS modules.
* **F5 CIS 2.13+**, **IngressLink 2.10+**, **NGINX Plus IC R30+** (if you explore WAF).
* Simple **static routes** between BIG‑IP and the cluster are enough for single‑box demos.

---

## 3  Mini‑Glossary (the *why* behind every tool)
* **Git vs GitHub** – Git stores version history on your disk; GitHub is the cloud where you _push_ commits so team‑mates (or CI) can _pull_ & merge.
* **VS Code** – shows YAML schema errors in red _before_ `oc apply` fails; the OpenShift Toolkit lets you browse pods & logs without leaving the editor.
* **OpenShift CLI `oc`** – superset of `kubectl` with extra verbs like `oc adm policy` or `oc create route`.  Authenticate once, then scripts just work.
* **Helm** – templating engine; we use it only to install NGINX Ingress.
* **BIG‑IP** – external ADC providing L4/L7 load‑balancing, TLS, WAF, DNS GSLB.  Labs start with static routing connectivity and get fancier later.

---

## 4  Repository Layout Blueprint
```text
juice-shop-labs/
├── 00-clusterip-internal/   # Scenario 0 – ClusterIP only
│   ├── README.md            # (this file’s Chapter A – copy out later)
│   └── manifests/
│       ├── juice-shop-deployment.yaml
│       └── juice-shop-service.yaml   # ClusterIP Service
├── 01-nodeport/            # Scenario 1 – NodePort only
│   ├── README.md            # (Chapter B below)
│   └── manifests/
│       ├── juice-shop-deployment.yaml
│       └── juice-shop-service.yaml   # NodePort Service
┆   one folder per matrix row …
├── scripts/     # reusable bash (cleanup, smoke‑test)
├── assets/      # diagrams, sample TLS certs
└── prerequisites-and-matrix.md  # THIS master readme
```
Numeric prefixes match the matrix rows – easy cross‑reference on stream.

---

## 5  Deployment‑Option Matrix (_pick your adventure_)

| #  | Scenario & Folder                                                | Front‑to‑Back Path                  | In‑Cluster Controller(s) | External LB / ADC | TLS Termination | HTTPS Redirect    | GSLB / Fail‑over     | Connectivity to OCP | Ops Owner              | Primary Purpose        |
| -- | ---------------------------------------------------------------- | ----------------------------------- | ------------------------ | ----------------- | --------------- | ----------------- | -------------------- | ------------------- | ---------------------- | ---------------------- |
| 0  | ClusterIP – [`00-clusterip-internal/`](00-clusterip-internal/README.md)                             | Pod → Service (ClusterIP)           | n/a                      | n/a               | None            | Manual            | n/a                  | n/a                 | Dev→Dev                | East‑west / unit tests |
| 1  | NodePort – [`01-nodeport/`](01-nodeport/README.md)                                        | Pod → Service (NodePort)            | n/a                      | n/a               | None            | Manual            | n/a                  | direct node IP      | Dev                    | Quick PoC              |
| 2  | ext‑NGINX LB – `02-ext-nginx-nodeport/`                          | NodePort exposed via external NGINX | n/a                      | NGINX             | External NGINX  | Optional          | DNS round‑robin      | n/a                 | NetOps                 | DIY LB between workers |
| 3  | Route (edge) – `03-route-edge/`                                  | HAProxy Router                      | HAProxy Router           | Router            | Router (edge)   | Yes               | Wildcard DNS         | SDN / OVN           | Dev→DevOps             | Native PROD pattern    |
| 4  | Route → NGINX OSS IC – `04-route-ic-oss/`                        | Router → Ingress                    | NGINX OSS IC             | Router            | None (HTTP)     | n/a               | ClusterIP svc        | -                   | DevOps                 | Path fan‑out demo      |
| 5  | Edge TLS → NGINX OSS IC – `05-route-ic-oss-edgeTLS/`             | Router(edge TLS) → IC               | NGINX OSS IC             | Router            | Router (edge)   | Yes               | ClusterIP svc        | -                   | DevOps               | Central cert mgmt & L7 |
| 6  | Passthrough → NGINX OSS IC – `06-route-ic-oss-icTLS/`            | Router passthrough → IC TLS         | NGINX OSS IC             | Router            | IC              | Optional          | ClusterIP svc        | -                   | DevOps                 | mTLS / SNI policies    |
| 7  | BIG‑IP + CIS (ClusterIP) – `07-bigip-cis-clusterip/`             | ClusterIP via CIS                   | BIG‑IP CIS               | BIG‑IP            | Optional        | BIG‑IP DNS        | Static routes        | -                   | NetOps                 | Enterprise ADC         |
| 8  | BIG‑IP + CIS + NGINX OSS IC – `08-bigip-cis-ic-oss/`             | BIG‑IP front → IC                   | NGINX OSS IC             | BIG‑IP / IC       | Optional        | BIG‑IP DNS        | Static / BGP / VXLAN | -                   | DevOps + NetOps        | IC + ADC combo         |
| 9  | BIG‑IP + CIS + NGINX Plus IC + WAF – `09-bigip-cis-ic-plus-waf/` | BIG‑IP front → NGINX Plus IC + NAP  | NGINX Plus IC + NAP WAF  | BIG‑IP / IC       | Optional        | BIG‑IP DNS + EDNS | Static / BGP / VXLAN | -                   | SecOps + NetOps        | WAF & analytics        |
| 10 | BIG‑IP IngressLink – `10-bigip-ingresslink/`                     | BIG‑IP owns Ingress                 | BIG‑IP IngressLink       | BIG‑IP            | BIG‑IP          | Optional          | BIG‑IP DNS           | ARP / SNAT / VXLAN  | NetOps                 | Centralised ADC        |
| 11 | Multi‑Cluster GSLB wrapper – `11-mc-gslb/`                       | BIG‑IP DNS Failover wrapper         | Per‑cluster IC           | BIG‑IP DNS        | BIG‑IP          | Yes               | Authoritative GSLB   | Any (static/BGP)    | NetOps                 | Blue‑green / A‑P       |

---

| #  | Scenario & Folder              | External LB / ADC | TLS Term. | Redirect | GSLB | Primary goal |
|---|--------------------------------|-------------------|-----------|----------|------|--------------|
| 0 | ClusterIP → `00-clusterip-internal/` | n/a | none | manual | n/a | east‑west / unit tests |
| 1 | NodePort → `01-nodeport/` | n/a | none | manual | n/a | quick PoC |
| 2 | ext‑NGINX LB → `02-ext-nginx-nodeport/` | NGINX | external | opt | RR DNS | DIY LB |
| 3 | Route (edge) → `03-route-edge/` | Router | Router | yes | wildcard DNS | simple PROD |
| 4 | Route → NGINX OSS IC → `04-route-ic-oss/` | Router | none | n/a | svc IP | path fan‑out |
| 5 | edge TLS → NGINX OSS IC → `05-route-ic-oss-edgeTLS/` | Router | Router | — | svc | central certs |
| 6 | passthrough → NGINX OSS IC → `06-route-ic-oss-icTLS/` | Router | IC | — | svc | mTLS / SNI |
| 7 | BIG‑IP + CIS (ClusterIP) → `07-bigip-cis-clusterip/` | BIG‑IP | BIG‑IP | opt | BIG‑IP DNS | enterprise ADC |
| 8 | BIG‑IP + CIS + NGINX OSS IC → `08-bigip-cis-ic-oss/` | BIG‑IP | BIG‑IP/IC | opt | BIG‑IP DNS | IC + ADC combo |
| 9 | BIG‑IP + CIS + NGINX Plus IC + WAF → `09-bigip-cis-ic-plus-waf/` | BIG‑IP | BIG‑IP/IC | opt | GSLB+EDNS | WAF / analytics |
|10 | BIG‑IP IngressLink → `10-bigip-ingresslink/` | BIG‑IP | BIG‑IP | opt | BIG‑IP DNS | centralised ADC |
|11 | Multi‑Cluster GSLB wrapper → `11-mc-gslb/` | BIG‑IP DNS | BIG‑IP | yes | auth GSLB | blue‑green |

---

## 6  Next Step
*Clone the repo, pick a folder, follow its README.  Chapters A & B below are the first two folders already embedded here for quick copy‑paste.*

---