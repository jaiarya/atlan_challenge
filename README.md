
# Atlan Outage Simulation (Kubernetes) — Nginx + httpbin

This project reproduces a realistic multi-factor outage in Kubernetes using a **frontend (Nginx)** and **backend (httpbin)** in the **`atlan`** namespace. It demonstrates:

- **Service Discovery/DNS failure** via a **backend Service selector mismatch** (no Endpoints), compounded by a **default‑deny egress NetworkPolicy** blocking DNS to CoreDNS.
- **CrashLoop/InitLoop** on the frontend via an **initContainer** that requires backend DNS to resolve before Nginx starts.
- **Resource instability** via a **memory‑leak sidecar** that triggers **OOMKilled** and can surface **node MemoryPressure** in tighter clusters.
- Optional **NodePort Services** to reach frontend/backend from outside the cluster.

> Built for reproducible training: deploy the broken state, investigate with `kubectl`, visualize in Grafana, then apply fixes in order.

---

## Contents

- [Architecture](#architecture)
- [Prerequisites](#prerequisites)
- [Quick Start](#quick-start)
- [Manifests](#manifests)
  - [`broken.yaml` (core simulation)](#brokenyaml-core-simulation)
  - [`services-nodeport.yaml` (NodePort Services)](#services-nodeportyaml-nodeport-services)
  - [`allow-dns.yaml` (allow DNS egress)](#allow-dnsyaml-allow-dns-egress)
  - [`fixes.yaml` (service selector + resource tuning)](#fixesyaml-service-selector--resource-tuning)
- [What to Observe](#what-to-observe)
- [Runbook: Debug & Fix](#runbook-debug--fix)
- [Grafana Panels & Alerts (PromQL)](#grafana-panels--alerts-promql)
- [Cleanup](#cleanup)
- [Notes & Tips](#notes--tips)

---

## Architecture

```
+----------------------+           +----------------------+
| Frontend (Nginx)     |  DNS ->   | kube-dns/CoreDNS     |
|  - init: nslookup    |           +----------------------+
|  - sidecar: memleak  |  HTTP ->  +----------------------+
+----------------------+           | Backend (httpbin)    |
                                   |  pods: app=backend-  |
NetPol: default-deny egress        |         api          |
                                   +----------------------+

Service: backend-svc (selector mismatch: app=backend, pods use app=backend-api)
Result: No Endpoints -> DNS NXDOMAIN (for headless) or connection failure (ClusterIP)
```

---

## Prerequisites

- Kubernetes cluster (Kind/Minikube/EKS/AKS/GKE)
- `kubectl` configured to access the cluster
- (Optional) Metrics: Prometheus + Grafana for dashboards/alerts

> On Minikube, use `minikube addons enable metrics-server` for `kubectl top`.

---

## Quick Start

1) **Deploy the broken simulation** (namespace `atlan`):

```bash
kubectl apply -f broken.yaml
```

2) (Optional) **Switch Services to NodePort** so you can access from outside the cluster:

```bash
kubectl apply -f services-nodeport.yaml
```

3) **Observe the failure**:

```bash
kubectl get pods -n atlan -o wide
kubectl describe pod -n atlan -l app=frontend
kubectl logs -n atlan deploy/frontend -c dns-check --previous
kubectl get svc,ep -n atlan
kubectl run -n atlan -it --rm dns-test --image=busybox:1.36 --restart=Never -- nslookup backend-svc.atlan.svc.cluster.local
```

4) **Fix in order**:

```bash
# Allow DNS (CoreDNS)
kubectl apply -f allow-dns.yaml

# Fix service selector and (optionally) resource limits
kubectl apply -f fixes.yaml
```

5) **Validate recovery**:

```bash
kubectl rollout status deploy/frontend -n atlan
kubectl get endpoints backend-svc -n atlan
kubectl run -n atlan -it --rm curl --image=busybox:1.36 --restart=Never -- wget -qO- http://backend-svc.atlan.svc.cluster.local/get
kubectl top pods -n atlan
```

---

## Manifests

Place these files at the repo root.

### `broken.yaml` (core simulation)

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: atlan
---
# Backend: httpbin (healthy pods), labels intentionally NOT matching Service
apiVersion: apps/v1
kind: Deployment
metadata:
  name: backend
  namespace: atlan
spec:
  replicas: 2
  selector:
    matchLabels:
      app: backend-api
  template:
    metadata:
      labels:
        app: backend-api
    spec:
      containers:
      - name: httpbin
        image: kennethreitz/httpbin
        ports:
        - containerPort: 80
---
# Backend Service (INTENTIONALLY BROKEN selector). Start as ClusterIP by default.
apiVersion: v1
kind: Service
metadata:
  name: backend-svc
  namespace: atlan
spec:
  type: ClusterIP
  selector:
    app: backend              # WRONG: pods use app=backend-api
  ports:
  - name: http
    port: 80
    targetPort: 80
---
# Frontend: Nginx
# - initContainer: must resolve backend FQDN; fails if DNS/Endpoints are broken (Init:CrashLoopBackOff)
# - sidecar memleak: allocates memory continuously to trigger OOMKilled
apiVersion: apps/v1
kind: Deployment
metadata:
  name: frontend
  namespace: atlan
spec:
  replicas: 1
  selector:
    matchLabels:
      app: frontend
  template:
    metadata:
      labels:
        app: frontend
    spec:
      initContainers:
      - name: dns-check
        image: busybox:1.36
        env:
        - name: BACKEND_HOST
          value: "backend-svc.atlan.svc.cluster.local"
        command: ["sh","-c"]
        args:
        - |
          echo "Resolving ${BACKEND_HOST} before starting Nginx...";
          for i in $(seq 1 30); do
            nslookup "${BACKEND_HOST}" && exit 0 || echo "DNS resolve failed, retrying...";
            sleep 2;
          done
          echo "Error: Database host not found: ${BACKEND_HOST}";
          exit 1
      containers:
      - name: nginx
        image: nginx:alpine
        ports:
        - containerPort: 80
        resources:
          requests:
            cpu: "50m"
            memory: "50Mi"
          limits:
            cpu: "250m"
            memory: "150Mi"
        readinessProbe:
          httpGet:
            path: /
            port: 80
          initialDelaySeconds: 5
          periodSeconds: 10
        livenessProbe:
          httpGet:
            path: /
            port: 80
          initialDelaySeconds: 10
          periodSeconds: 15
      - name: memleak
        image: python:3.11-alpine
        command: ["python","-u","-c"]
        args:
        - |
          import time; buf=[]
          print("Starting memory growth to simulate OOM...")
          while True:
              buf.append("x"*10_000_000)  # ~10MB/s
              time.sleep(1)
        resources:
          requests:
            cpu: "50m"
            memory: "20Mi"
          limits:
            cpu: "250m"
            memory: "120Mi"
---
# Default-deny egress to simulate cloud/network policy blocking DNS
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-egress
  namespace: atlan
spec:
  podSelector: {}
  policyTypes: ["Egress"]
  egress: []
```

> **Why ClusterIP (not headless)?** With headless + no Endpoints, DNS returns NXDOMAIN. With ClusterIP + no Endpoints, DNS resolves to a ClusterIP but connections fail. Both simulate Service discovery breakage; ClusterIP is simpler when converting to NodePort later.

### `services-nodeport.yaml` (NodePort Services)

```yaml
apiVersion: v1
kind: Service
metadata:
  name: backend-svc
  namespace: atlan
spec:
  type: NodePort
  selector:
    app: backend              # still WRONG on purpose (no endpoints until fixed)
  ports:
    - name: http
      port: 80
      targetPort: 80
      nodePort: 30080
---
apiVersion: v1
kind: Service
metadata:
  name: frontend-svc
  namespace: atlan
spec:
  type: NodePort
  selector:
    app: frontend
  ports:
    - name: http
      port: 80
      targetPort: 80
      nodePort: 30081
```

### `allow-dns.yaml` (allow DNS egress)

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-dns
  namespace: atlan
spec:
  podSelector: {}
  policyTypes: ["Egress"]
  egress:
  - to:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: kube-system
      podSelector:
        matchLabels:
          k8s-app: kube-dns
    ports:
    - protocol: UDP
      port: 53
    - protocol: TCP
      port: 53
```

### `fixes.yaml` (service selector + resource tuning)

Use this when you want to **recover** the system after demonstrating the outage.

```yaml
---
apiVersion: v1
kind: Service
metadata:
  name: backend-svc
  namespace: atlan
spec:
  selector:
    app: backend-api      # FIX: match backend Deployment pods
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: frontend
  namespace: atlan
spec:
  template:
    spec:
      containers:
      - name: memleak
        resources:
          requests:
            cpu: "100m"
            memory: "128Mi"
          limits:
            cpu: "500m"
            memory: "512Mi"
```

> Alternatively, remove the `memleak` container entirely once you finish the exercise.

---

## What to Observe

- **Pods**: `frontend` initially `Init:CrashLoopBackOff` (DNS init fails), `backend` pods Running
- **Service/Endpoints**: `backend-svc` shows **no Endpoints** because of selector mismatch
- **NetworkPolicy**: `default-deny-egress` blocks DNS requests to CoreDNS
- **Logs**: Frontend init logs show `Error: Database host not found`
- **Metrics** (after fixes): `memleak` gets **OOMKilled**, rising restart counts; possibly node MemoryPressure in small clusters

Commands:

```bash
kubectl get pods -n atlan -o wide
kubectl describe pod -n atlan -l app=frontend
kubectl logs -n atlan deploy/frontend -c dns-check --previous
kubectl get svc,ep -n atlan
kubectl describe svc backend-svc -n atlan
kubectl get events -A --sort-by=.lastTimestamp | tail -n 50
kubectl top pods -n atlan; kubectl top nodes
```

---

## Runbook: Debug & Fix

1. **Identify CrashLoop/InitLoop**
   ```bash
   kubectl describe pod -n atlan -l app=frontend
   kubectl logs -n atlan deploy/frontend -c dns-check --previous
   ```
2. **Check Service discovery**
   ```bash
   kubectl get svc backend-svc -n atlan -o yaml
   kubectl get endpoints backend-svc -n atlan
   ```
3. **Test DNS from within the namespace**
   ```bash
   kubectl run -n atlan -it --rm dns-test --image=busybox:1.36 --restart=Never -- nslookup backend-svc.atlan.svc.cluster.local
   ```
4. **NetworkPolicy sanity**
   ```bash
   kubectl get netpol -n atlan
   kubectl get svc -n kube-system kube-dns -o wide
   ```
5. **Apply fixes**
   ```bash
   kubectl apply -f allow-dns.yaml
   kubectl apply -f fixes.yaml
   ```
6. **Validate**
   ```bash
   kubectl rollout status deploy/frontend -n atlan
   kubectl get endpoints backend-svc -n atlan
   kubectl run -n atlan -it --rm curl --image=busybox:1.36 --restart=Never -- wget -qO- http://backend-svc.atlan.svc.cluster.local/get
   ```

---

## Grafana Panels & Alerts (PromQL)

**Pod restarts (frontend):**
```promql
increase(kube_pod_container_status_restarts_total{namespace="atlan", pod=~"frontend-.*"}[1h])
```

**OOMKilled count:**
```promql
increase(container_oom_events_total{namespace="atlan"}[30m])
```

**Container memory vs limit (frontend memleak):**
```promql
container_memory_working_set_bytes{namespace="atlan", pod=~"frontend-.*", container="memleak"}
/
kube_pod_container_resource_limits{namespace="atlan", pod=~"frontend-.*", container="memleak", resource="memory"}
```

**Node MemoryPressure:**
```promql
max by (node) (kube_node_status_condition{condition="MemoryPressure", status="true"})
```

**Suggested alerts:**
```promql
# CrashLoop burst
increase(kube_pod_container_status_restarts_total{namespace="atlan"}[10m]) > 5

# DNS SERVFAIL/NXDOMAIN (requires CoreDNS exporter or logs->metrics)
rate(coredns_dns_response_rcode_count_total{rcode=~"SERVFAIL|NXDOMAIN"}[5m]) > 5

# OOM risk
(
  container_memory_working_set_bytes{namespace="atlan"}
  /
  kube_pod_container_resource_limits{namespace="atlan", resource="memory"}
) > 0.9
```

---

## Cleanup

```bash
kubectl delete ns atlan
```

---

## Notes & Tips

- If you used `services-nodeport.yaml`, access from outside the cluster (node reachable):
  - Frontend: `http://<NODE_IP>:30081/`
  - Backend:  `http://<NODE_IP>:30080/get`
- On Minikube, use:
  ```bash
  minikube service frontend-svc -n atlan --url
  minikube service backend-svc  -n atlan --url
  ```
- To increase realism for cloud (EKS): ensure Security Groups/NACLs allow egress to DNS (UDP/TCP 53) and to any external DBs/APIs your workloads need.

---

### License
MIT (use and adapt freely for internal training and demos)
