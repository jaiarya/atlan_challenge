# Atlan Challenge

This Challenge reproduces an outage in Kubernetes using a **frontend (Nginx)** and **backend (http-echo)** in the **`atlan`** namespace. It demonstrates:

- **Service Discovery/DNS failure** via a **backend Service selector mismatch** (no Endpoints).
- **CrashLoop** on the frontend though the wrong configuration of the deployment.
- **Resource instability** via a **memory‑leak sidecar** that triggers **OOMKilled** and can surface **node MemoryPressure** in tighter clusters.

---

## Contents

- [Environment](#environment)
- [Symptoms](#symptoms)
- [Manifests](#manifests)
  - [`deployment-backend.yaml`](#deployment-backendyaml) - This contains 1 replicas using `http-echo` image container used for simple HTTP request & response service with `backend-ok`
  - [`deployment-frontend.yaml`](#deployment-frontendyaml) - This contains 1 replicas using `nginx:1.25-alpine` image container listening to port `80` .
  - [`service-backend.yaml`](#service-backendyaml) - I have not exposed this externally for security reason hence used *ClusterIP*, this will only communicate to frontend service.
  - [`service-frontend.yaml`](#service-frontendyaml) - I have exposed this as a NodePort acting as a Frontend service.
- [Troubleshoot](#troubleshoot)
- [Observations](#observations)
- [Solution](#solution)
- [Result](#result)
---

## Environment

- For this challenge, I am using a minikube cluster with three nodes (1 control plane, and 2 worker nodes). 
```
[jai@localhost ~]$ k get nodes
NAME           STATUS   ROLES           AGE   VERSION
minikube       Ready    control-plane   22h   v1.34.0
minikube-m02   Ready    worker          22h   v1.34.0
minikube-m03   Ready    worker          3h    v1.34.0
```
- We have two pods running, one for the  frontend and one for the backend.
```
[jai@localhost ~]$ k get po
NAME                               READY   STATUS              RESTARTS   AGE
backend-deploy-7f866bd874-fq89l    1/1     Running             0          39m
frontend-deploy-69dc57b85c-ztxsr   1/1     Running             0          28m
```
- Frontend service is exposed as NodePort and backend service as ClusterIP.
```
[jai@localhost ~]$ k get svc
NAME           TYPE        CLUSTER-IP      EXTERNAL-IP   PORT(S)        AGE
backend-svc    ClusterIP   10.102.68.45    <none>        5678/TCP       65m
frontend-svc   NodePort    10.100.203.49   <none>        80:30080/TCP   65m
```
- I am using node *`minikube-m02`* to run both the front-end pod and stress pod to induce node memory stress.
```
[jai@localhost ~]$ kubectl get pods -o wide --field-selector spec.nodeName=minikube-m02
NAME                               READY   STATUS    RESTARTS       AGE    IP            NODE           NOMINATED NODE   READINESS GATES
frontend-deploy-7484474544-8fkx6   1/1     Running   4 (151m ago)   157m   10.244.1.3    minikube-m02   <none>           <none>
memory-stress                      1/1     Running   0              53m    10.244.1.11   minikube-m02   <none>           <none>
```
- Prometheus and Grafana are installed in the *`monitoring`* namespace
```
[jai@localhost ~]$ k get po -n monitoring
NAME                                                    READY   STATUS    RESTARTS       AGE
alertmanager-kps-kube-prometheus-stack-alertmanager-0   2/2     Running   0              160m
kps-grafana-78cb598f5b-4d4gl                            3/3     Running   7 (176m ago)   3h12m
kps-kube-prometheus-stack-operator-64898c88b5-pd22l     1/1     Running   3 (175m ago)   3h12m
kps-kube-state-metrics-64b5b64889-f7sk2                 1/1     Running   3 (175m ago)   3h12m
kps-prometheus-node-exporter-86rrh                      1/1     Running   1 (40m ago)    160m
kps-prometheus-node-exporter-9q67c                      1/1     Running   1 (177m ago)   3h6m
kps-prometheus-node-exporter-rr8ll                      1/1     Running   2 (176m ago)   18h
prometheus-kps-kube-prometheus-stack-prometheus-0       2/2     Running   3 (176m ago)   18h
```
- I have used ApacheBench (ab) to perform a high-load HTTP stress test against the endpoint.
```
ab -n 200000 -c 2000 http://192.168.49.3:30080/
```
---
## Symptoms

- While trying to access the backend via API, it reports a bad gateway.
```
[jai@localhost atlan]$ k -n atlan exec -it frontend-deploy-7484474544-8fkx6 -- curl -v backend-svc.atlan.svc.cluster.local:5678
* Host backend-svc.atlan.svc.cluster.local:5678 was resolved.
* IPv6: (none)
* IPv4: 10.102.68.45
*   Trying 10.102.68.45:5678...
* connect to 10.102.68.45 port 5678 from 10.244.1.3 port 45612 failed: Connection refused
* Failed to connect to backend-svc.atlan.svc.cluster.local port 5678 after 5 ms: Couldn't connect to server
* Closing connection
curl: (7) Failed to connect to backend-svc.atlan.svc.cluster.local port 5678 after 5 ms: Couldn't connect to server
command terminated with exit code 7
```
---
## Manifests

### `deployment-backend.yaml`

```
apiVersion: apps/v1
kind: Deployment
metadata:
  name: backend-deploy
  namespace: atlan
  labels:
    app: backend-api
spec:
  replicas: 1
  selector:
    matchLabels:
      app: backend-api
  template:
    metadata:
      labels:
        app: backend-api
    spec:
      containers:
        - name: backend
          image: hashicorp/http-echo:0.2.3
          args:
            - "-text=backend-ok"
          ports:
            - containerPort: 5678
```

### `deployment-frontend.yaml`
```
apiVersion: apps/v1
kind: Deployment
metadata:
  name: frontend-deploy
  namespace: atlan
  labels:
    app: frontend
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

      nodeSelector:
        node-role: memory-pressure

      containers:
        - name: nginx
          image: nginx:1.25-alpine
          ports:
            - containerPort: 80
          resources:
            requests:
              cpu: "250m"
              memory: "64Mi"
            limits:
              cpu: "250m"
              memory: "128Mi"
          volumeMounts:
            - name: nginx-conf
              mountPath: /etc/nginx/conf.d
      volumes:
        - name: nginx-conf
          configMap:
            name: frontend-nginx-conf
            items:
              - key: default.conf
                path: default.conf
```

### `service-backend.yaml`
```
apiVersion: v1
kind: Service
metadata:
  name: backend-svc
  namespace: atlan
  labels:
    app: backend
spec:
  type: ClusterIP
  selector:
    app: backend
  ports:
    - name: http
      port: 5678
      targetPort: 5678
```
### `service-frontend.yaml`
```
apiVersion: v1
kind: Service
metadata:
  name: frontend-svc
  namespace: atlan
  labels:
    app: frontend
spec:
  type: NodePort
  selector:
    app: frontend
  ports:
    - name: http
      port: 80
      targetPort: 80
      nodePort: 30080
```
---

## Troubleshoot

1. Both the services are reporting fine and describing the **frontend-svc** reports no issue/events, but the endpoint reports empty
```
[jai@localhost k8s]$ k get svc,ep
Warning: v1 Endpoints is deprecated in v1.33+; use discovery.k8s.io/v1 EndpointSlice
NAME                   TYPE        CLUSTER-IP      EXTERNAL-IP   PORT(S)        AGE
service/backend-svc    ClusterIP   10.102.68.45    <none>        5678/TCP       8h
service/frontend-svc   NodePort    10.100.203.49   <none>        80:30080/TCP   8h

NAME                     ENDPOINTS       AGE
endpoints/backend-svc    <none>          8h
endpoints/frontend-svc   10.244.1.3:80   8h

[jai@localhost k8s]$ k describe svc frontend-svc
Name:                     frontend-svc
Namespace:                atlan
Labels:                   app=frontend
Annotations:              <none>
Selector:                 app=frontend
Type:                     NodePort
IP Family Policy:         SingleStack
IP Families:              IPv4
IP:                       10.100.203.49
IPs:                      10.100.203.49
Port:                     http  80/TCP
TargetPort:               80/TCP
NodePort:                 http  30080/TCP
Endpoints:                10.244.1.3:80
Session Affinity:         None
External Traffic Policy:  Cluster
Internal Traffic Policy:  Cluster
Events:                   <none>
```

2. Checking the corresponding pod with the help of the node selector reporting in Crashloop.
```
[jai@localhost ~]$ k get pods -l app=frontend
NAME                               READY   STATUS      RESTARTS        AGE
frontend-deploy-69dc57b85c-ztxsr   0/1     OOMKilled   2 (3m49s ago)   42m
```
3. Describing the pod reports OOMKill, but no abnormal events found.
```
[jai@localhost ~]$ k describe pods frontend-deploy-69dc57b85c-ztxsr
Name:             frontend-deploy-69dc57b85c-ztxsr
Namespace:        atlan
Priority:         0
Service Account:  default
Node:             minikube-m02/192.168.49.3
Start Time:       Thu, 13 Nov 2025 13:08:18 +0530
Labels:           app=frontend
                  pod-template-hash=69dc57b85c
Annotations:      <none>
Status:           Running
IP:               10.244.1.20
IPs:
  IP:           10.244.1.20
Controlled By:  ReplicaSet/frontend-deploy-69dc57b85c
Containers:
  nginx:
    Container ID:   docker://9c1538b9f183ee36993b7ee3edfb200b3d41610019a50178ff5501945da80761
    Image:          nginx:1.25-alpine
    Image ID:       docker-pullable://nginx@sha256:516475cc129da42866742567714ddc681e5eed7b9ee0b9e9c015e464b4221a00
    Port:           80/TCP
    Host Port:      0/TCP
    State:          Waiting
      Reason:       CrashLoopBackOff
    Last State:     Terminated
      Reason:       OOMKilled    <<<<<<<<<<<<<<<< Container reports OOMKilled
      Exit Code:    137
      Started:      Thu, 13 Nov 2025 13:47:37 +0530
      Finished:     Thu, 13 Nov 2025 13:51:08 +0530
    Ready:          False
    Restart Count:  2
    Limits:
      cpu:     250m
      memory:  7Mi
    Requests:
      cpu:        250m
      memory:     6Mi
    Environment:  <none>
    Mounts:
      /etc/nginx/conf.d from nginx-conf (rw)
      /var/run/secrets/kubernetes.io/serviceaccount from kube-api-access-hslql (ro)
Conditions:
  Type                        Status
  PodReadyToStartContainers   True 
  Initialized                 True 
  Ready                       False 
  ContainersReady             False 
  PodScheduled                True 
Volumes:
  nginx-conf:
    Type:      ConfigMap (a volume populated by a ConfigMap)
    Name:      frontend-nginx-conf
    Optional:  false
  kube-api-access-hslql:
    Type:                    Projected (a volume that contains injected data from multiple sources)
    TokenExpirationSeconds:  3607
    ConfigMapName:           kube-root-ca.crt
    Optional:                false
    DownwardAPI:             true
QoS Class:                   Burstable
Node-Selectors:              <none>
Tolerations:                 node.kubernetes.io/not-ready:NoExecute op=Exists for 300s
                             node.kubernetes.io/unreachable:NoExecute op=Exists for 300s
Events:
  Type     Reason     Age                  From               Message
  ----     ------     ----                 ----               -------
  Normal   Scheduled  43m                  default-scheduler  Successfully assigned atlan/frontend-deploy-69dc57b85c-ztxsr to minikube-m02
  Normal   Pulled     3m52s (x3 over 43m)  kubelet            Container image "nginx:1.25-alpine" already present on machine
  Normal   Created    3m52s (x3 over 43m)  kubelet            Created container: nginx
  Normal   Started    3m52s (x3 over 43m)  kubelet            Started container nginx
  Warning  BackOff    6s (x3 over 4m7s)    kubelet            Back-off restarting failed container nginx in pod frontend-deploy-69dc57b85c-ztxsr_atlan(3c76cb75-15dc-47f2-92e3-e456f1c4803c)

```
4.  Grafana reports that the Port started reporting restart after 15:30 IST.
<img width="669" height="310" alt="Screenshot 2025-11-13 at 3 43 46 PM" src="https://github.com/user-attachments/assets/4056e879-a3cf-4f17-846c-e454aa7415e9" />


   - We do see around the same time, Memory limit is been hit:
<img width="844" height="324" alt="Screenshot 2025-11-13 at 3 44 24 PM" src="https://github.com/user-attachments/assets/81b277bb-d7af-4928-b861-eba22a089420" />

5. Frontend Port reports multiple restarts.
<img width="1187" height="388" alt="Screenshot 2025-11-13 at 2 15 22 PM" src="https://github.com/user-attachments/assets/8352912c-98a5-4cd3-bea2-ef617e65c6fc" />      

6. Running a test pod to check the DNS test from inside the namespace works though.

```
[jai@localhost k8s]$ kubectl run -n atlan -it --rm dns-test --image=busybox:1.36 --restart=Never -- nslookup backend-svc.atlan.svc.cluster.local
Server:         10.96.0.10
Address:        10.96.0.10:53


Name:   backend-svc.atlan.svc.cluster.local
Address: 10.102.68.45

pod "dns-test" deleted from atlan namespace
```
7. No error reported in the kube-dns.
```
kubectl logs -n kube-system -l k8s-app=kube-dns
[INFO] 10.244.1.8:42338 - 44646 "AAAA IN kps-kube-prometheus-stack-prometheus.monitoring.monitoring.svc.cluster.local. udp 105 false 1232" NXDOMAIN qr,aa,rd 187 0.000176317s
[INFO] 10.244.1.8:33585 - 6426 "A IN kps-kube-prometheus-stack-prometheus.monitoring.monitoring.svc.cluster.local. udp 105 false 1232" NXDOMAIN qr,aa,rd 187 0.000360684s
[INFO] 10.244.1.8:34195 - 9244 "AAAA IN kps-kube-prometheus-stack-prometheus.monitoring.svc.cluster.local. udp 94 false 1232" NOERROR qr,aa,rd 176 0.000088867s
[INFO] 10.244.1.8:39436 - 27273 "A IN kps-kube-prometheus-stack-prometheus.monitoring.svc.cluster.local. udp 94 false 1232" NOERROR qr,aa,rd 164 0.000161486s
[INFO] 10.244.1.8:35055 - 4319 "A IN kps-kube-prometheus-stack-prometheus.monitoring.monitoring.svc.cluster.local. udp 105 false 1232" NXDOMAIN qr,aa,rd 187 0.0001676s
[INFO] 10.244.1.8:41634 - 23939 "AAAA IN kps-kube-prometheus-stack-prometheus.monitoring.monitoring.svc.cluster.local. udp 105 false 1232" NXDOMAIN qr,aa,rd 187 0.000212123s
[INFO] 10.244.1.8:43071 - 43988 "A IN kps-kube-prometheus-stack-prometheus.monitoring.svc.cluster.local. udp 94 false 1232" NOERROR qr,aa,rd 164 0.000126113s
[INFO] 10.244.1.8:49481 - 33819 "AAAA IN kps-kube-prometheus-stack-prometheus.monitoring.svc.cluster.local. udp 94 false 1232" NOERROR qr,aa,rd 176 0.000269899s
[INFO] 10.244.1.11:48098 - 20480 "AAAA IN backend-svc.atlan.svc.cluster.local. udp 53 false 512" NOERROR qr,aa,rd 146 0.000169003s
[INFO] 10.244.1.11:48098 - 4729 "A IN backend-svc.atlan.svc.cluster.local. udp 53 false 512" NOERROR qr,aa,rd 104 0.000189343s
```

8. Accessing the Grafana Dashboard - it reports no DNS errors, but Node Memory has been exhausted.
<img width="601" height="232" alt="Screenshot 2025-11-13 at 6 41 37 PM" src="https://github.com/user-attachments/assets/ccb2ccb4-b969-4804-9136-db7d5785ea7f" />

   - Node Memory Pressure
<img width="756" height="304" alt="Screenshot 2025-11-13 at 6 40 22 PM" src="https://github.com/user-attachments/assets/50f7d393-e169-43df-9f1b-9fdf2ff9aa87" />

9. While reviewing the `frontend-deploy` deployment, we could see that the nginx container doesn't have a realistic memory limit or request.

```
[jai@localhost k8s]$ k get deploy/frontend-deploy -oyaml| grep -A6 "resources:"
        resources:
          limits:
            cpu: 250m
            memory: 7Mi
          requests:
            cpu: 250m
            memory: 6Mi
```
10. Reviewing further, we could have another pod running on the same node no limit set and causing the Memory pressure on the node.

```

[jai@localhost k8s]$ kubectl get pods -o wide --field-selector spec.nodeName=minikube-m02
NAME                               READY   STATUS    RESTARTS        AGE     IP            NODE           NOMINATED NODE   READINESS GATES
frontend-deploy-7484474544-8fkx6   1/1     Running   4 (6h30m ago)   6h36m   10.244.1.3    minikube-m02   <none>           <none>
memory-stress                      1/1     Running   0               5h36m   10.244.1.13   minikube-m02   <none>           <none>

[jai@localhost k8s]$ k get po memory-stress -oyaml| grep -A6 "resources:"
    resources:
      requests:
        memory: 50Mi
```

11. Further checking on the SVC lookup failure, we could see that the backend pod works fine.

```
[jai@localhost k8s]$ kgp -owide
NAME                               READY   STATUS    RESTARTS        AGE     IP           NODE           NOMINATED NODE   READINESS GATES
backend-deploy-7f866bd874-dznd6    1/1     Running   1 (5h8m ago)    5h24m   10.244.0.8   minikube       <none>           <none>
frontend-deploy-7484474544-8fkx6   1/1     Running   4 (4h44m ago)   4h50m   10.244.1.3   minikube-m02   <none>           <none>
[jai@localhost k8s]$ k -n atlan exec -it frontend-deploy-7484474544-8fkx6 -- ping 10.244.0.8
PING 10.244.0.8 (10.244.0.8): 56 data bytes
64 bytes from 10.244.0.8: seq=0 ttl=62 time=0.180 ms
64 bytes from 10.244.0.8: seq=1 ttl=62 time=0.097 ms
^C
--- 10.244.0.8 ping statistics ---
2 packets transmitted, 2 packets received, 0% packet loss
round-trip min/avg/max = 0.097/0.138/0.180 ms
```

12. Reviewing the backend SVC and its corresponding pods reports *No Resources found*

```
[jai@localhost k8s]$ k get svc backend-svc
NAME          TYPE        CLUSTER-IP     EXTERNAL-IP   PORT(S)    AGE
backend-svc   ClusterIP   10.102.68.45   <none>        5678/TCP   10h

[jai@localhost k8s]$ k describe svc backend-svc
Name:                     backend-svc
Namespace:                atlan
Labels:                   app=backend
Annotations:              <none>
Selector:                 app=backend
Type:                     ClusterIP
IP Family Policy:         SingleStack
IP Families:              IPv4
IP:                       10.102.68.45
IPs:                      10.102.68.45
Port:                     http  5678/TCP
TargetPort:               5678/TCP
Endpoints:                
Session Affinity:         None
Internal Traffic Policy:  Cluster
Events:                   <none>

[jai@localhost k8s]$ k get pods -l app=backend
No resources found in atlan namespace.
```

13. When checking the pod labels, it reports the label as `app=backend-api` while the label on the service it is `app=backend`

```
[jai@localhost k8s]$ kubectl get pods --show-labels
NAME                               READY   STATUS    RESTARTS        AGE     LABELS
backend-deploy-7f866bd874-dznd6    1/1     Running   1 (6h37m ago)   6h53m   app=backend-api,pod-template-hash=7f866bd874
frontend-deploy-7484474544-8fkx6   1/1     Running   4 (6h13m ago)   6h19m   app=frontend,pod-template-hash=7484474544
```
---
## Observations

1. The frontend pod (nginx) is configured with unrealistically low memory limits, hence causing .
2. *Node MemoryPressure* is triggering due to another pod not having any limit set.
3. The backend Service (backend-svc) had a selector mismatch:
    -  Service selector: app=backend
    -  Pod label: app=backend-api
4. Grafana dashboard showed:
    - Pod memory usage hitting limits
    - OOMKilled terminations
    - Pod restart spikes

---
## Solution


1. Fix the frontend resource configuration.

  - Set realistic memory limits and requests:
```
resources:
  requests:
    memory: "64Mi"
  limits:
    memory: "256Mi"
```
2. Set the limit for the `memory-stress` pod or delete it completely if not needed.

3. Fix backend service selector
```
kubectl -n atlan patch svc backend-svc -p '{"spec":{"selector":{"app":"backend-api"}}}'
```
---

### Result

- API from the frontend is successful.

```
[jai@localhost atlan]$ k -n atlan exec -it frontend-deploy-7c785796dd-bh9ld -- curl -v backend-svc.atlan.svc.cluster.local:5678
* Host backend-svc.atlan.svc.cluster.local:5678 was resolved.
* IPv6: (none)
* IPv4: 10.102.68.45
*   Trying 10.102.68.45:5678...
* Connected to backend-svc.atlan.svc.cluster.local (10.102.68.45) port 5678
> GET / HTTP/1.1
> Host: backend-svc.atlan.svc.cluster.local:5678
> User-Agent: curl/8.5.0
> Accept: */*
> 
< HTTP/1.1 200 OK
< X-App-Name: http-echo
< X-App-Version: 0.2.3
< Date: Thu, 13 Nov 2025 19:15:34 GMT
< Content-Length: 11
< Content-Type: text/plain; charset=utf-8
< 
backend-ok
* Connection #0 to host backend-svc.atlan.svc.cluster.local left intact
```

- No pod restart since the changes.

```
[jai@localhost ~]$ kgp
NAME                               READY   STATUS    RESTARTS      AGE
backend-deploy-7f866bd874-dznd6    1/1     Running   1 (32h ago)   33h
frontend-deploy-7c785796dd-bh9ld   1/1     Running   0             24h
```

<img width="1189" height="316" alt="Screenshot 2025-11-14 at 12 50 26 AM" src="https://github.com/user-attachments/assets/5b00bb48-d17c-45b3-a58d-1d990698ac2d" />

- Node Memory usage have been dropped.
<img width="1194" height="315" alt="Screenshot 2025-11-14 at 12 50 57 AM" src="https://github.com/user-attachments/assets/c11410d8-2d60-4d67-8347-ee2c4ded77c1" />
