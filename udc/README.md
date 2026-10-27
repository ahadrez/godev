# UDC — Secret Manager POC (OpenShift + GCP)

Mount a GCP Secret Manager secret into the `goapp-sm` app on OpenShift.
Keyless (Workload Identity Federation), nothing stored in etcd.

## What's here

```
udc/
├── 1-gcp-setup.sh          # run FIRST  — sets up the GCP side
├── 2-openshift-deploy.sh   # run SECOND — deploys everything to OpenShift
└── manifests/
    ├── 00-rbac-scc.yaml    # cluster-scoped RBAC + SCC (platform team if you lack rights)
    ├── 10-provider.yaml    # Google Secret Manager CSI provider DaemonSet
    └── 20-app.yaml         # SecretProviderClass + goapp-sm Deployment/Service/Route
```

Fixed values (edit the top of the scripts to change):
OpenShift namespace `ucod-hadrezak-sandbox` · GCP project `udc-d-30049622-stella-1`
· secret `csi-poc-password` · app image `quay.io/upstream/goapp-sm`

## Prerequisites (once)

- `oc login` to the LZ OpenShift cluster, `gcloud auth login` with LZ credentials.
- The Red Hat **Secrets Store CSI Driver operator** is already installed on the cluster.
- Cluster nodes can reach `sts.googleapis.com` and `secretmanager.googleapis.com` on 443.

## Steps

```bash
cd udc

# 1. GCP side: secret + workload identity federation + credential file
./1-gcp-setup.sh

# 2. OpenShift side: provider + app (applies manifests/, creates the WIF ConfigMap)
./2-openshift-deploy.sh
```

That's it. The deploy script prints the app URL at the end — open it, the page
shows **Loaded** with the masked secret value.

## Verify

```bash
oc -n ucod-hadrezak-sandbox get pods                  # provider + goapp-sm Running
oc -n ucod-hadrezak-sandbox get secret csi-poc-password   # NotFound = good (not in etcd)
```

## If something is stuck

- Pod `ContainerCreating` + `PermissionDenied` in events → IAM/WIF mismatch: re-run `./1-gcp-setup.sh` (idempotent) and check its output.
- `provider not found` in events → provider DaemonSet not Running, or SCC missing (`manifests/00-rbac-scc.yaml` needs cluster-admin).
- `ImagePullBackOff` → quay repo private? Add a pull secret to the namespace.

## Cleanup

```bash
oc delete -f manifests/ --ignore-not-found
# GCP: delete the secret + WIF pool (commands printed by 1-gcp-setup.sh --cleanup)
```
